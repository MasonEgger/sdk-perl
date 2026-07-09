# ABOUTME: Workflow dispatcher (spec section 8.3): decodes a WorkflowActivation,
# ABOUTME: routes by run_id to a cached per-run Workflow::Runner, applies the
# ABOUTME: codec boundary, handles the RemoveFromCache eviction fast path, and
# ABOUTME: builds + sends the WorkflowActivationCompletion.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
use feature 'try';
no warnings 'experimental::try';

use Future ();
use Future::AsyncAwait;
use Protobuf::Class::Accessor ();
use Scalar::Util ();

use Temporalio::Converter::Payload ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Bridge ();
use Temporalio::Workflow::Runner ();

# The two message types the codec walker special-cases (spec R7, finding R6):
# every temporal.api.common.v1.Payload in the tree goes through the codec
# chain, EXCEPT those inside a SearchAttributes message — the server must be
# able to index SA values, so they stay codec-free in both directions
# (MUST-match sdk-python bridge/_visitor.py skip_search_attributes; the
# step-45 Review Record sub-claim 1 verified Python keeps SAs codec-free).
my $PAYLOAD_TYPE           = 'temporal.api.common.v1.Payload';
my $SEARCH_ATTRIBUTES_TYPE = 'temporal.api.common.v1.SearchAttributes';

class Temporalio::Worker::WorkflowDispatcher {
    # Temporalio::Worker::WorkflowRegistry: workflow type name -> backing class.
    field $registry :param;

    # Temporalio::Converter::Data: provides the payload converter the per-run
    # Runner uses for value conversion AND the codec chain the dispatcher applies
    # at the worker boundary (spec section 8.3 steps 5 + 8).
    field $data_converter :param;

    # The worker's task queue — handed to each Runner as the default task queue
    # for activities the workflow schedules without an explicit queue.
    field $task_queue :param = undef;

    # The worker's namespace (the client's namespace) — handed to each Runner so
    # Temporalio::Workflow::info and external-workflow signal/cancel commands
    # carry the correct NamespacedWorkflowExecution namespace (spec section 20).
    field $namespace :param = 'default';

    # Eager activity dispatch (spec section 23.2): the workflow-side flag,
    # handed to each Runner so scheduled activities set do_not_eagerly_execute.
    field $disable_eager_activity_execution :param = 0;

    # Worker versioning (spec §29.1): true only when the worker runs in
    # versioned mode, so each Runner may report the per-workflow
    # :VersioningBehavior in its completion. Core rejects a versioning_behavior
    # from a non-versioned worker, so this defaults off.
    field $report_versioning_behavior :param = 0;

    # Whether the worker enabled the local-activity path (workflows && activities
    # registered). Threaded to each Runner so execute_local_activity fails cleanly
    # when the worker built with enable_local_activities => 0 (#9).
    field $local_activities_enabled :param = 1;

    # The combined worker interceptor list (client-supplied then worker-supplied,
    # spec section 27.2), threaded to each Runner so the workflow-inbound chain
    # is built and actually invoked for execute_workflow / handle_signal /
    # handle_query / handle_update (#10).
    field $interceptors :param = [];

    # Worker-level failure-routing options (spec R14+R15, findings A1/ADJ2),
    # threaded to each Runner via _runner_failure_options below. Pre-fix the
    # worker misrouted the type list into core's per-workflow-TYPE field and
    # dropped the boolean, so live Runners ran with defaults while the replay
    # harness (Test/WorkflowReplay.pm) threaded both: live/replay divergence.
    field $workflow_failure_exception_types :param = [];
    field $nondeterminism_as_workflow_fail  :param = 0;

    # A coderef ($completion_bytes) -> Future: sends the serialized
    # WorkflowActivationCompletion to core (worker_complete_workflow_activation
    # over the callback bridge). Injectable so unit tests capture completions
    # without a live worker.
    field $completer :param;

    # Optional coderef ($run_id, $remove_from_cache_job) invoked on every
    # eviction BEFORE the empty completion is sent (sdk-python parity:
    # _workflow.py on_eviction_hook). The replay path (spec R43, finding R14)
    # uses it to read the eviction reason; NONDETERMINISM is how core reports
    # a history mismatch. Live workers leave it unset.
    field $on_eviction :param = undef;

    # run_id => Temporalio::Workflow::Runner. One Runner per workflow run, kept
    # for the life of the run; dropped on RemoveFromCache (eviction). MUST-match
    # sdk-python _running_workflows (keyed by act.run_id).
    field %runners;

    # Proto classes resolved once.
    field $WorkflowActivation;
    field $Completion;

    ADJUST {
        $WorkflowActivation = Temporalio::Core::Proto::resolve(
            'coresdk.workflow_activation.WorkflowActivation');
        $Completion = Temporalio::Core::Proto::resolve(
            'coresdk.workflow_completion.WorkflowActivationCompletion');
    }

    method registry       { $registry }
    method data_converter { $data_converter }
    method workflow_failure_exception_types { $workflow_failure_exception_types }
    method nondeterminism_as_workflow_fail  { $nondeterminism_as_workflow_fail }

    # The single naming point for the failure-routing plumbing keys (spec
    # R14+R15 REFACTOR): the pairs below MUST use the exact
    # Workflow::Runner constructor parameter names, which are also the
    # Worker->new kwarg names and the Test::WorkflowReplay kwarg names: one
    # name end to end, so the live path (here) and the replay harness
    # (Test/WorkflowReplay.pm) cannot drift apart again (findings A1/ADJ2).
    method _runner_failure_options () {
        return (
            workflow_failure_exception_types => $workflow_failure_exception_types,
            nondeterminism_as_workflow_fail  => $nondeterminism_as_workflow_fail,
        );
    }
    method has_runner ($run_id) { exists $runners{$run_id} ? 1 : 0 }
    method runner     ($run_id) { return $runners{$run_id} }

    # dispatch_task($activation_bytes) -> Future (spec section 8.3 steps 1-10).
    # Decode the activation, take the RemoveFromCache fast path when it is the
    # only/last job, else codec-decode the inbound payloads, route by run_id to a
    # (created-or-cached) Runner, process the activation, codec-encode the
    # outbound payloads, and send the completion. Activation processing runs
    # under a catch-all (spec R11, finding R5): the completion contract with
    # core is one completion per activation, so ANY die on the way to a
    # completion — codec decode, runner creation (unregistered type, missing
    # init job), the Runner itself — maps to a FAILED completion that is still
    # sent, never an escaped die the poll loop would have to swallow (which
    # left the workflow task uncompleted and the workflow wedged until timeout).
    # MUST-match sdk-python _handle_activation's catch-all except branch.
    async method dispatch_task ($activation_bytes) {
        my $activation = $WorkflowActivation->decode($activation_bytes);
        my $run_id     = $activation->run_id;
        my @jobs       = ($activation->jobs // [])->@*;

        # Step 4 — eviction. RemoveFromCache is guaranteed to be the only job in
        # its activation (proto comment), but if it ever arrives alongside other
        # jobs it is applied LAST: the run is torn down and the response is the
        # empty-success eviction completion, regardless of the other jobs
        # (MUST-match sdk-python _handle_activation: a cache_remove_job short-
        # circuits to _handle_cache_eviction and returns).
        if (defined(my $remove_job = _eviction_job(\@jobs))) {
            return await $self->_handle_eviction($run_id, $remove_job);
        }

        my $completion;
        try {
            # Step 5 — codec-decode every inbound payload at the worker boundary
            # so the Runner only ever sees decoded payloads.
            await $self->_codec_decode_activation($activation);

            # Step 6 — route by run_id; create a Runner on the first activation
            # for a run (which must carry an InitializeWorkflow job).
            my $runner = $self->_runner_for($run_id, $activation);

            # Step 7 — process the activation (synchronous from the loop's
            # view: the Runner applies all jobs and pumps to a completion). The
            # Runner builds the completion from nested hashrefs, so round-trip
            # it through encode/decode to bless every sub-message (Success, each
            # WorkflowCommand, its payloads) before walking it for the codec
            # boundary — mirrors the replay harness, and matches how core hands
            # bytes back.
            $completion = $runner->process_activation($activation);
            $completion = $Completion->decode($completion->encode);
            $completion->set_run_id($run_id) if $completion->run_id ne $run_id;
        }
        catch ($err) {
            $completion = $self->_failed_completion_for($run_id, $err);
        }

        # Step 8 — codec-encode every outbound payload (success or failure
        # content both cross the codec boundary). Guarded so an encode die still
        # honors the completion contract (sdk-python parity: the completion is
        # replaced with a bare failed one, never dropped).
        try {
            await $self->_codec_encode_completion($completion);
        }
        catch ($err) {
            $completion = $Completion->decode($Completion->new({
                run_id => $run_id,
                failed => {
                    failure => { message => "Failed encoding completion: $err" },
                },
            })->encode);
        }

        # Step 9 — send the completion bytes.
        await $self->_send($completion);
        return;
    }

    # Map a die that escaped activation processing to the completion the core
    # contract requires (spec R11, finding R5; MUST-match sdk-python
    # _handle_activation). A NON-RETRYABLE ApplicationError fails the WORKFLOW
    # terminally (a successful completion whose sole command is
    # FailWorkflowExecution); anything else fails the workflow TASK (the
    # `failed` status, which the server retries). Failure conversion is itself
    # guarded (sdk-python "Failed converting activation exception") so a
    # converter die can never re-escape and break the contract.
    method _failed_completion_for ($run_id, $err) {
        my $failure;
        {
            local $@;
            $failure = eval {
                $data_converter->failure_converter->to_failure(
                    $err, $data_converter->payload_converter);
            };
            $failure //=
                { message => "Failed converting activation exception: $@" };
        }

        my $completion;
        if (Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Application')
            && $err->non_retryable)
        {
            $completion = $Completion->new({
                run_id     => $run_id,
                successful => { commands => [
                    { fail_workflow_execution => { failure => $failure } },
                ] },
            });
        }
        else {
            $completion = $Completion->new({
                run_id => $run_id,
                failed => { failure => $failure },
            });
        }
        # Round-trip so every sub-message is blessed for the codec walker.
        return $Completion->decode($completion->encode);
    }

    # Eviction fast path (spec section 8.3 step 4 / 10.3 RemoveFromCache): tear
    # down the cached Runner (if any), report the RemoveFromCache job to the
    # on_eviction hook (reason + message, the replay path's nondeterminism
    # signal, spec R43), and send an empty successful completion without
    # invoking any workflow code. Tolerates an uncached run (cache miss).
    async method _handle_eviction ($run_id, $remove_job = undef) {
        if (my $runner = delete $runners{$run_id}) {
            $runner->evict;
        }
        $on_eviction->($run_id, $remove_job) if defined $on_eviction;
        my $completion = $Completion->new({
            run_id     => $run_id,
            successful => { commands => [] },
        });
        await $self->_send($completion);
        return;
    }

    # Find or create the Runner for $run_id. A cache miss requires the activation
    # to carry an InitializeWorkflow job (the run's first activation); its
    # workflow_type routes to the backing class via the registry. A cache miss
    # with no init job is a bridge-level error (the run was evicted unexpectedly
    # — mirrors sdk-python's RuntimeError).
    method _runner_for ($run_id, $activation) {
        my $runner = $runners{$run_id};
        return $runner if defined $runner;

        my $init = _initialize_job($activation);
        if (!defined $init) {
            Temporalio::Exception::Bridge->throw(
                message => "Workflow activation for run '$run_id' has no cached "
                    . "runner and no InitializeWorkflow job (the run may have "
                    . "been unexpectedly evicted)");
        }

        my $type  = $init->workflow_type;
        my $class = $registry->definition($type);
        if (!defined $class) {
            Temporalio::Exception::Bridge->throw(
                message => "Workflow type '$type' is not registered on this "
                    . "worker");
        }

        $runner = Temporalio::Workflow::Runner->new(
            workflow_class    => $class,
            run_id            => $run_id,
            payload_converter => $data_converter->payload_converter,
            failure_converter => $data_converter->failure_converter,
            task_queue        => $task_queue,
            namespace         => $namespace,
            disable_eager_activity_execution => $disable_eager_activity_execution,
            report_versioning_behavior => $report_versioning_behavior,
            local_activities_enabled   => $local_activities_enabled,
            interceptors               => $interceptors,
            # spec R14+R15 (findings A1/ADJ2): the failure-routing options,
            # which pre-fix never reached a live Runner.
            $self->_runner_failure_options,
        );
        $runners{$run_id} = $runner;
        return $runner;
    }

    # Send the completion (step 9): serialize and hand the bytes to the injected
    # completer. A send failure is surfaced (the worker decides whether it is
    # fatal — spec section 8.3).
    async method _send ($completion) {
        await $completer->($completion->encode);
        return;
    }

    # --- codec boundary (spec section 8.3 steps 5 + 8; spec R7, finding R6) --
    # The runner converts values with the bare payload_converter; codecs are a
    # worker-boundary concern applied here over EVERY payload embedded in the
    # activation (decode) and the completion (encode). One directional walker
    # covers the whole tree, so a future job/command kind cannot bypass the
    # codec the way the enumerated v0.1 boundary let the v0.2 surfaces slip
    # through (update input, child/nexus results, failure details, memo,
    # headers, update/query responses, continue-as-new args, local-activity
    # args, signal-external args, memo upserts — finding R6). Search
    # attributes are the deliberate exception (see $SEARCH_ATTRIBUTES_TYPE).

    async method _codec_decode_activation ($activation) {
        return unless @{ $data_converter->payload_codecs };
        await $self->_apply_codec_to_message($activation, 'decode');
        return;
    }

    async method _codec_encode_completion ($completion) {
        return unless @{ $data_converter->payload_codecs };
        await $self->_apply_codec_to_message($completion, 'encode');
        return;
    }

    # The single directional codec helper (spec R7): recursively walk a fully
    # decoded proto message via its schema descriptor and run every embedded
    # Payload through the codec chain in $direction, replacing it in place —
    # singular fields through their setter, repeated fields and map values
    # through the live reference the generated reader returns. Payloads inside
    # a SearchAttributes message are never offered to the chain (sdk-python
    # skip_search_attributes parity). Map keys are visited in sorted order so
    # the codec call sequence is deterministic.
    async method _apply_codec_to_message ($msg, $direction) {
        my $descriptor = $msg->descriptor;
        return if $descriptor->full_name eq $SEARCH_ATTRIBUTES_TYPE;

        for my $field ($descriptor->fields->@*) {
            next unless $field->is_message;
            my $reader = Protobuf::Class::Accessor::accessor_name($field->name);

            if ($field->is_map) {
                my $value_message = _map_value_message($field) // next;
                my $map = $msg->$reader;
                next unless %$map;
                if ($value_message->full_name eq $PAYLOAD_TYPE) {
                    my @keys  = sort keys %$map;
                    my $coded = await $self->_run_codec(
                        $direction, [ @{$map}{@keys} ]);
                    @{$map}{@keys} = @$coded;
                }
                else {
                    for my $key (sort keys %$map) {
                        next unless Scalar::Util::blessed($map->{$key});
                        await $self->_apply_codec_to_message(
                            $map->{$key}, $direction);
                    }
                }
            }
            elsif ($field->is_repeated) {
                my $type = $field->type_ref // next;
                my $list = $msg->$reader;
                next unless @$list;
                if ($type->full_name eq $PAYLOAD_TYPE) {
                    @$list = @{ await $self->_run_codec($direction, [@$list]) };
                }
                else {
                    for my $item (@$list) {
                        next unless Scalar::Util::blessed($item);
                        await $self->_apply_codec_to_message($item, $direction);
                    }
                }
            }
            else {
                my $type  = $field->type_ref // next;
                my $value = $msg->$reader    // next;
                if ($type->full_name eq $PAYLOAD_TYPE) {
                    my $coded  = await $self->_run_codec($direction, [$value]);
                    my $setter = "set_$reader";
                    $msg->$setter($coded->[0]);
                }
                elsif (Scalar::Util::blessed($value)) {
                    await $self->_apply_codec_to_message($value, $direction);
                }
            }
        }
        return;
    }

    # Run one payload batch through the data converter's codec chain in the
    # given direction (the converter applies chain ordering: list order on
    # encode, reverse on decode).
    async method _run_codec ($direction, $payloads) {
        return $direction eq 'encode'
            ? await $data_converter->codec_encode($payloads)
            : await $data_converter->codec_decode($payloads);
    }

    # --- job inspection helpers ----------------------------------------------
    # File-scope subs (a bare `class` file puts them in main:: — lessons.md, but
    # these take no $self so name them plainly inside the block).

    # The RemoveFromCache message of the activation's eviction job, or undef
    # when the activation carries none. The job's reason/message ride to the
    # on_eviction hook (spec R43).
    sub _eviction_job ($jobs) {
        for my $job (@$jobs) {
            return $job->remove_from_cache
                if ($job->which_variant // '') eq 'remove_from_cache';
        }
        return undef;
    }

    sub _initialize_job ($activation) {
        for my $job (($activation->jobs // [])->@*) {
            return $job->initialize_workflow
                if ($job->which_variant // '') eq 'initialize_workflow';
        }
        return undef;
    }

    # The Schema::Message of a map field's VALUE type (field number 2 of the
    # synthetic MapEntry the field's type_ref points at), or undef when the
    # map's values are scalar (e.g. Payload.metadata's bytes) and the codec
    # walker has nothing to visit.
    sub _map_value_message ($field) {
        my $entry = $field->type_ref // return undef;
        my ($value_field) = grep { $_->number == 2 } $entry->fields->@*;
        return undef unless $value_field && $value_field->is_message;
        return $value_field->type_ref;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::WorkflowDispatcher - route workflow activations to per-run runners

=head1 SYNOPSIS

    use Temporalio::Worker::WorkflowDispatcher ();

    my $dispatcher = Temporalio::Worker::WorkflowDispatcher->new(
        registry       => $workflow_registry,
        data_converter => $data_converter,
        task_queue     => 'demo',
        completer      => sub ($bytes) { ... return Future },
    );

    await $dispatcher->dispatch_task($activation_bytes);

=head1 DESCRIPTION

The workflow dispatcher of spec section 8.3. C<dispatch_task> decodes a
serialized C<coresdk.workflow_activation.WorkflowActivation> and:

=over

=item *

B<Eviction fast path.> If any job is C<RemoveFromCache> (guaranteed by core to
be the only job, but applied last if combined), the cached
L<Temporalio::Workflow::Runner> for the run is torn down (C<< ->evict >>) and an
B<empty successful completion> is sent without invoking any workflow code
(T-wf-14, mirrors sdk-python C<_handle_cache_eviction>). An uncached run is
tolerated (cache miss).

=item *

B<Codec boundary.> Inbound activation payloads are codec-B<decoded> and outbound
completion payloads codec-B<encoded> (spec section 8.3 steps 5 + 8), so the
runner only ever sees decoded payloads and does value conversion with the bare
payload converter. The boundary is a single directional walker over the whole
proto tree (spec R7, finding R6): every embedded
C<temporal.api.common.v1.Payload> passes through the codec chain, B<except>
payloads inside a C<SearchAttributes> message, which stay codec-free in both
directions so the server can index them (sdk-python C<skip_search_attributes>
parity). See L<Temporalio::Converter::PayloadCodec/WORKER CODEC BOUNDARY> for
the covered-surface list.

=item *

B<run_id routing.> Activations route by C<run_id> to a per-run Runner; the first
activation for a run (which must carry an C<InitializeWorkflow> job) creates the
Runner from the job's C<workflow_type> via the
L<Temporalio::Worker::WorkflowRegistry>, and it is cached for the life of the
run. A cache miss with no init job raises L<Temporalio::Exception::Bridge>.

=item *

B<Failure catch-all.> The completion contract with core is one completion per
activation (spec R11, finding R5): any die on the way to a completion — codec
decode, runner creation (unregistered type, missing init job), or a die
escaping the Runner — maps to a B<failed> completion that is still sent
(sdk-python C<_handle_activation> parity). A non-retryable
L<Temporalio::Exception::Application> fails the workflow terminally instead
(a C<FailWorkflowExecution> command); a codec-encode die replaces the
completion with a bare failed one. C<dispatch_task> therefore only fails when
the completion cannot be B<sent>.

=back

The runner processes the activation synchronously and returns a
C<WorkflowActivationCompletion>; its codec-encoded bytes are handed to the
injected C<completer>. Making the completer injectable lets unit tests capture
completions without a live worker; L<Temporalio::Worker> supplies a real one
that issues C<worker_complete_workflow_activation> over the callback bridge.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Worker::WorkflowDispatcher->new(
        registry => ...,
        data_converter => ...,
        task_queue => ...,
        completer => ...,
    );

Constructs a Temporalio::Worker::WorkflowDispatcher. Named parameters:

=over 4

=item C<registry>

(required)

=item C<data_converter>

(required)

=item C<task_queue>

(optional, default C<undef>)

=item C<completer>

(required)

=item C<on_eviction>

(optional, default C<undef>)
Coderef C<($run_id, $remove_from_cache_job)> invoked on every eviction before the empty completion is sent (sdk-python C<on_eviction_hook> parity).
The replay path reads the job's C<reason>/C<message> to detect nondeterminism (spec R43); live workers leave it unset.

=item C<workflow_failure_exception_types>

(optional, default C<[]>)
Exception class names routed to every live Runner (spec R14, finding A1); a listed class escaping C<:Run> fails the workflow instead of the task.

=item C<nondeterminism_as_workflow_fail>

(optional, default C<0>)
When true, a detected nondeterminism fails the workflow instead of the task on every live Runner (spec R15, finding ADJ2).

=back

=head1 METHODS

=head2 data_converter

Accessor returning the C<data_converter> value.

=head2 workflow_failure_exception_types

Accessor returning the C<workflow_failure_exception_types> value.

=head2 nondeterminism_as_workflow_fail

Accessor returning the C<nondeterminism_as_workflow_fail> value.

=head2 dispatch_task

Async. Routes one polled workflow activation to the per-run L<Temporalio::Workflow::Runner> and returns a L<Future> resolving to the completion.

=head2 has_runner

Returns true if a runner exists for the given run id.

=head2 registry

Accessor returning the C<registry> value.

=head2 runner

Returns the L<Temporalio::Workflow::Runner> for the given run id, creating one if needed.

=cut
