# ABOUTME: Workflow dispatcher (spec section 8.3): decodes a WorkflowActivation,
# ABOUTME: routes by run_id to a cached per-run Workflow::Runner, applies the
# ABOUTME: codec boundary, handles the RemoveFromCache eviction fast path, and
# ABOUTME: builds + sends the WorkflowActivationCompletion.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

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

    # A coderef ($completion_bytes) -> Future: sends the serialized
    # WorkflowActivationCompletion to core (worker_complete_workflow_activation
    # over the callback bridge). Injectable so unit tests capture completions
    # without a live worker.
    field $completer :param;

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
    method has_runner ($run_id) { exists $runners{$run_id} ? 1 : 0 }
    method runner     ($run_id) { return $runners{$run_id} }

    # dispatch_task($activation_bytes) -> Future (spec section 8.3 steps 1-10).
    # Decode the activation, take the RemoveFromCache fast path when it is the
    # only/last job, else codec-decode the inbound payloads, route by run_id to a
    # (created-or-cached) Runner, process the activation, codec-encode the
    # outbound payloads, and send the completion.
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
        if (_has_eviction(\@jobs)) {
            return await $self->_handle_eviction($run_id);
        }

        # Step 5 — codec-decode every inbound payload at the worker boundary so
        # the Runner only ever sees decoded payloads.
        await $self->_codec_decode_activation($activation);

        # Step 6 — route by run_id; create a Runner on the first activation for a
        # run (which must carry an InitializeWorkflow job).
        my $runner = $self->_runner_for($run_id, $activation);

        # Step 7 — process the activation (synchronous from the loop's view: the
        # Runner applies all jobs and pumps to a completion). The Runner builds
        # the completion from nested hashrefs, so round-trip it through
        # encode/decode to bless every sub-message (Success, each WorkflowCommand,
        # its payloads) before walking it for the codec boundary — mirrors the
        # replay harness, and matches how core hands bytes back.
        my $completion = $runner->process_activation($activation);
        $completion = $Completion->decode($completion->encode);
        $completion->set_run_id($run_id) if $completion->run_id ne $run_id;

        # Step 8 — codec-encode every outbound payload.
        await $self->_codec_encode_completion($completion);

        # Step 9 — send the completion bytes.
        await $self->_send($completion);
        return;
    }

    # Eviction fast path (spec section 8.3 step 4 / 10.3 RemoveFromCache): tear
    # down the cached Runner (if any) and send an empty successful completion
    # without invoking any workflow code. Tolerates an uncached run (cache miss).
    async method _handle_eviction ($run_id) {
        if (my $runner = delete $runners{$run_id}) {
            $runner->evict;
        }
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

    sub _has_eviction ($jobs) {
        for my $job (@$jobs) {
            return 1 if ($job->which_variant // '') eq 'remove_from_cache';
        }
        return 0;
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

=back

=head1 METHODS

=head2 data_converter

Accessor returning the C<data_converter> value.

=head2 dispatch_task

Async. Routes one polled workflow activation to the per-run L<Temporalio::Workflow::Runner> and returns a L<Future> resolving to the completion.

=head2 has_runner

Returns true if a runner exists for the given run id.

=head2 registry

Accessor returning the C<registry> value.

=head2 runner

Returns the L<Temporalio::Workflow::Runner> for the given run id, creating one if needed.

=cut
