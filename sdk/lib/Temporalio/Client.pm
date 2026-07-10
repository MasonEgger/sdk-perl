# ABOUTME: Temporal client (spec section 7): async connect over the callback
# ABOUTME: bridge, holding the connection, namespace, identity, and converter.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
use feature 'try';
no warnings 'experimental::try';

use Future::AsyncAwait;
use Scalar::Util ();
use Sys::Hostname ();
use Temporalio::Converter::Data;
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Client::AsyncActivityHandle ();
use Temporalio::Client::Connection ();
use Temporalio::Client::HttpConnectProxyConfig ();
use Temporalio::Client::KeepAliveConfig ();
use Temporalio::Client::RetryConfig ();
use Temporalio::Client::TlsConfig ();
use Temporalio::Client::Interceptor ();
use Temporalio::Client::_RootOutbound ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Client::WorkflowExecutionIterator ();
use Temporalio::Client::ScheduleHandle ();
use Temporalio::Client::ScheduleListIterator ();
use Temporalio::Common::Options ();
use Temporalio::Common::TypedSearchAttributes ();
use Temporalio::Common::VersioningOverride ();
use Temporalio::Interceptor::Headers ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::RpcError ();
use Temporalio::Exception::ScheduleAlreadyRunning ();
use Temporalio::Exception::WorkflowAlreadyStarted ();
use Temporalio::Schedule::Schedule ();
use Temporalio::Schedule::Policy ();
use Temporalio::Schedule::Action ();
use Temporalio::Runtime ();
use Temporalio::SDK ();

class Temporalio::Client {
    # Workflow-id reuse/conflict policy spec strings -> proto enum numbers.
    # MUST match temporal.api.enums.v1.WorkflowId{Reuse,Conflict}Policy
    # (introspected from the vendored proto; cross-checked against sdk-python
    # temporalio/common.py WorkflowIDReusePolicy / WorkflowIDConflictPolicy).
    my %ID_REUSE_POLICY = (
        unspecified                 => 0,
        allow_duplicate             => 1,
        allow_duplicate_failed_only => 2,
        reject_duplicate            => 3,
        terminate_if_running        => 4,
    );
    my %ID_CONFLICT_POLICY = (
        unspecified        => 0,
        fail               => 1,
        use_existing       => 2,
        terminate_existing => 3,
    );

    field $connection     :param;    # Temporalio::Client::Connection
    field $namespace      :param;
    field $identity       :param;
    field $data_converter :param;
    field $runtime        :param;
    # Interceptors (spec section 27): the ordered list passed to connect; the
    # first-listed interceptor is outermost. The worker inherits this list and
    # appends its own (Worker.pm). $_outbound_chain is built lazily from the
    # list folded over a root impl that performs the real RPC.
    field $interceptors   :param = [];
    field $_outbound_chain;
    # The connect-level default query reject condition (spec R93; parity audit
    # client finding 4, Python _client.py:144-145,184-187): applied by
    # WorkflowHandle::query when the per-call reject_condition is omitted; a
    # per-call value wins. Stored as given (a Python-parity name or a raw proto
    # number); the R67 name-to-enum map validates it at query time, pre-RPC.
    field $default_workflow_query_reject_condition :param = undef;

    method connection     { $connection }
    method namespace      { $namespace }
    method identity       { $identity }
    method data_converter { $data_converter }
    method runtime        { $runtime }
    method interceptors   { $interceptors }
    method default_workflow_query_reject_condition
        { $default_workflow_query_reject_condition }

    # The raw gRPC service handles (spec R91; Python _client.py:307-322):
    # the low-level escape hatch for RPCs the high-level client does not
    # wrap, e.g. operator search-attribute management. Delegates to the
    # connection, which owns the rpc funnel, exactly as Python's accessors
    # delegate to the service client.
    method workflow_service { $connection->workflow_service }
    method operator_service { $connection->operator_service }

    # _outbound — the client outbound interceptor chain head (spec section 27.2).
    # Built once: a root OutboundInterceptor whose methods perform the real
    # RPC, wrapped by the interceptor list (first-listed outermost).
    method _outbound () {
        return $_outbound_chain //=
            Temporalio::Client::Interceptor::build_outbound_chain(
                $interceptors,
                Temporalio::Client::_RootOutbound->new(client => $self));
    }

    # Rotation is manual and explicit (spec section 7.3): no refresh timer,
    # no refresh-on-UNAUTHENTICATED. Synchronous, no RPC.
    method update_api_key ($api_key) {
        $connection->update_api_key($api_key);
        return;
    }

    # get_workflow_handle($workflow_id, run_id => ..., first_execution_run_id
    # => ...) — returns a Temporalio::Client::WorkflowHandle without an RPC
    # (spec section 7.4).
    method get_workflow_handle ($workflow_id, %opts) {
        Temporalio::Common::Options::assert_known_keys(
            'get_workflow_handle', \%opts,
            { run_id => 1, first_execution_run_id => 1 });
        Temporalio::Exception::Argument->throw(
            message => 'get_workflow_handle requires a workflow id')
            unless defined $workflow_id && length $workflow_id;
        return Temporalio::Client::WorkflowHandle->new(
            client                 => $self,
            workflow_id            => $workflow_id,
            run_id                 => $opts{run_id},
            first_execution_run_id => $opts{first_execution_run_id},
        );
    }

    # _build_reset_workflow_request($id, $run_id, %kwargs) — builds the same
    # ResetWorkflowExecutionRequest as the handle helper, via a transient
    # handle, without issuing any RPC (unit-testable). Spec section 30.1.
    method _build_reset_workflow_request ($workflow_id, $run_id, %kwargs) {
        my $handle = $self->get_workflow_handle($workflow_id, run_id => $run_id);
        return $handle->_build_reset_request(%kwargs);
    }

    # reset_workflow($id, $run_id, %kwargs) — async (spec section 30.1): the
    # client-level entry point for the reset helper; delegates to a handle.
    # Returns the new run id.
    async method reset_workflow ($workflow_id, $run_id, %kwargs) {
        my $handle = $self->get_workflow_handle($workflow_id, run_id => $run_id);
        return await $handle->reset(%kwargs);
    }

    # async_activity_handle(%kw) — keyword-union factory (spec section 22.1) for
    # an activity completing out of band. Either:
    #   task_token => $bytes
    #   workflow_id => $w, run_id => $r (optional), activity_id => $a
    # task_token is mutually exclusive with the id triple; workflow_id requires
    # activity_id. No RPC at construction. Returns a
    # Temporalio::Client::AsyncActivityHandle.
    method async_activity_handle (%kw) {
        Temporalio::Common::Options::assert_known_keys(
            'async_activity_handle', \%kw,
            { task_token => 1, workflow_id => 1, run_id => 1,
              activity_id => 1 });
        my $task_token  = delete $kw{task_token};
        my $workflow_id = delete $kw{workflow_id};
        my $run_id      = delete $kw{run_id};
        my $activity_id = delete $kw{activity_id};

        my $has_token = defined $task_token;
        my $has_any_id = defined $workflow_id
            || defined $run_id || defined $activity_id;

        if ($has_token && $has_any_id) {
            Temporalio::Exception::Argument->throw(
                message => 'async_activity_handle: task_token is mutually '
                         . 'exclusive with workflow_id/run_id/activity_id');
        }
        if ($has_token) {
            return Temporalio::Client::AsyncActivityHandle->new(
                client     => $self,
                task_token => $task_token,
            );
        }
        # id-reference path: workflow_id AND activity_id are required.
        unless (defined $workflow_id && length $workflow_id
            && defined $activity_id && length $activity_id) {
            Temporalio::Exception::Argument->throw(
                message => 'async_activity_handle requires either a task_token '
                         . 'or both workflow_id and activity_id');
        }
        return Temporalio::Client::AsyncActivityHandle->new(
            client       => $self,
            id_reference => {
                workflow_id => $workflow_id,
                run_id      => $run_id,
                activity_id => $activity_id,
            },
        );
    }

    # start_workflow($workflow_or_string, \@args, %kwargs) — async (spec
    # section 7.4). Builds the StartWorkflowExecutionRequest, issues it over
    # _rpc_call (ALREADY_EXISTS special-cased to WorkflowAlreadyStarted via
    # the spec section 7.5 mapping), and returns a WorkflowHandle whose run_id
    # is the response's first run id.
    async method start_workflow ($workflow, $args = [], %kwargs) {
        my $headers = delete $kwargs{headers} // {};
        my $input = Temporalio::Client::Interceptor::Input::StartWorkflow->new(
            workflow => $workflow,
            args     => [ @$args ],
            headers  => { %$headers },
            kwargs   => { %kwargs },
        );
        return await $self->_outbound->start_workflow($input);
    }

    # _root_start_workflow($input) — the chain root: performs the real RPC
    # using the (possibly interceptor-mutated) args/headers (spec section 27.2).
    async method _root_start_workflow ($input) {
        my %kwargs = %{ $input->get('kwargs') };
        my $request = await $self->_build_start_workflow_request(
            $input->get('workflow'), $input->args,
            %kwargs, headers => $input->headers);
        my $workflow_id = $request->workflow_id;
        my $response = await $self->_rpc_call(
            'StartWorkflowExecution', $request,
            error_context => {
                workflow_id   => $workflow_id,
                workflow_type => $request->workflow_type->name,
            });
        return Temporalio::Client::WorkflowHandle->new(
            client                 => $self,
            workflow_id            => $workflow_id,
            run_id                 => $response->run_id,
            first_execution_run_id => $response->run_id,
            # Eager start (spec section 23.1, detect-only): the response carries
            # an eager_workflow_task message when the server returned the first
            # workflow task for the shared core client to execute eagerly.
            eagerly_started        => (defined $response->eager_workflow_task ? 1 : 0),
        );
    }

    # execute_workflow(...) — convenience: start then await result. result()
    # lands in P1.11; the helper is wired here for completeness once it does.
    async method execute_workflow ($workflow, $args = [], %kwargs) {
        my $handle = await $self->start_workflow($workflow, $args, %kwargs);
        return await $handle->result;
    }

    # signal_with_start_workflow($workflow_or_string, \@args, %kwargs) — async
    # (spec section 7.4). Same kwargs as start_workflow plus signal =>
    # $name, signal_args => \@args.
    async method signal_with_start_workflow ($workflow, $args = [], %kwargs) {
        # SignalWithStartWorkflowInput has no top-level headers (they live on
        # the embedded start op, spec section 27.1).
        my $input =
            Temporalio::Client::Interceptor::Input::SignalWithStartWorkflow->new(
                workflow => $workflow,
                args     => [ @$args ],
                kwargs   => { %kwargs },
            );
        return await $self->_outbound->signal_with_start_workflow($input);
    }

    async method _root_signal_with_start_workflow ($input) {
        my %kwargs = %{ $input->get('kwargs') };
        my $request = await $self->_build_signal_with_start_workflow_request(
            $input->get('workflow'), $input->args, %kwargs);
        my $workflow_id = $request->workflow_id;
        my $response = await $self->_rpc_call(
            'SignalWithStartWorkflowExecution', $request,
            error_context => {
                workflow_id   => $workflow_id,
                workflow_type => $request->workflow_type->name,
            });
        return Temporalio::Client::WorkflowHandle->new(
            client                 => $self,
            workflow_id            => $workflow_id,
            run_id                 => $response->run_id,
            first_execution_run_id => $response->run_id,
        );
    }

    # list_workflows($query, page_size => 100): synchronous. Returns the
    # iterator itself (an object with one async method, ->next, yielding one
    # WorkflowExecutionInfo per await and undef when exhausted; spec section
    # 7.4 / R64, finding A9; sdk-python _impl.py list_workflows 391-394).
    # No RPC until the first ->next is awaited.
    method list_workflows ($query = undef, %opts) {
        Temporalio::Common::Options::assert_known_keys(
            'list_workflows', \%opts, { page_size => 1 });
        return Temporalio::Client::_WorkflowExecutionIterator->new(
            client    => $self,
            query     => $query,
            # Python sends page_size 1000 when the caller omits it (finding
            # A17 / spec R69; ../sdk-python/temporalio/client/_client.py:1230);
            # before R69 this SDK sent no page_size at all.
            page_size => $opts{page_size} // 1000,
        );
    }

    # count_workflows($query) — async; returns { count => N, groups => [...] }
    # (spec section 7.4; sdk-python _impl.py count_workflows 396-409).
    async method count_workflows ($query = undef, %opts) {
        Temporalio::Common::Options::assert_known_keys(
            'count_workflows', \%opts, {});
        my $request = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.CountWorkflowExecutionsRequest')
            ->new({
                namespace => $namespace,
                query     => $query // '',
            });
        my $response =
            await $self->_rpc_call('CountWorkflowExecutions', $request);
        my $groups = $response->groups;
        return {
            count  => $response->count // 0,
            groups => [ defined $groups ? @$groups : () ],
        };
    }

    # get_schedule_handle($id) — returns a Temporalio::Client::ScheduleHandle
    # without an RPC (spec section 25.1).
    method get_schedule_handle ($id) {
        Temporalio::Exception::Argument->throw(
            message => 'get_schedule_handle requires a schedule id')
            unless defined $id && length $id;
        return Temporalio::Client::ScheduleHandle->new(client => $self, id => $id);
    }

    # create_schedule($id, $schedule, %opts) — async (spec section 25.2).
    # Validates the limited/remaining-actions invariant before any RPC, builds
    # the optional initial_patch (only when trigger_immediately or backfills),
    # issues CreateSchedule, re-maps an ALREADY_EXISTS to
    # ScheduleAlreadyRunning, and returns a handle.
    #   %opts: trigger_immediately => 0, backfills => [], memo => undef,
    #          search_attributes => undef
    # Finding A17 (spec R69): Python's kwarg is `backfill` (singular,
    # sdk-python client/_client.py:2675); this SDK shipped Ruby's plural
    # `backfills` (sdk-ruby client.rb:684). Accept both forms wired to the
    # same initial_patch.backfill_request (_impl.py:1184-1194); reject the
    # ambiguous call carrying both.
    async method create_schedule ($id, $schedule, %opts) {
        Temporalio::Common::Options::assert_known_keys(
            'create_schedule', \%opts,
            { trigger_immediately => 1, backfill => 1, backfills => 1,
              memo => 1, search_attributes => 1 });
        Temporalio::Exception::Argument->throw(
            message => 'create_schedule takes backfill or backfills, '
                     . 'not both')
            if exists $opts{backfill} && exists $opts{backfills};
        my $trigger   = delete $opts{trigger_immediately} // 0;
        my $backfills = delete $opts{backfills} // delete $opts{backfill}
                     // [];
        my $memo      = delete $opts{memo};
        my $sa        = delete $opts{search_attributes};
        Temporalio::Exception::Argument->throw(
            message => 'create_schedule requires a schedule id')
            unless defined $id && length $id;
        Temporalio::Exception::Argument->throw(
            message => 'create_schedule requires a Temporalio::Schedule::Schedule')
            unless Scalar::Util::blessed($schedule)
                && $schedule->isa('Temporalio::Schedule::Schedule');

        # limited_actions must be true exactly when remaining_actions is
        # non-zero (sdk-python _impl create_schedule).
        my $state     = $schedule->state;
        my $limited   = $state->limited_actions;
        my $remaining = $state->remaining_actions // 0;
        if ($limited && !$remaining) {
            Temporalio::Exception::Argument->throw(
                message => 'limited_actions requires a non-zero '
                         . 'remaining_actions');
        }
        if (!$limited && $remaining) {
            Temporalio::Exception::Argument->throw(
                message => 'remaining_actions requires limited_actions to be '
                         . 'true');
        }

        my %fields = (
            namespace   => $namespace,
            schedule_id => $id,
            schedule    => await $schedule->_to_proto($self),
            identity    => $identity,
            request_id  => _new_uuid(),
        );

        # initial_patch only when triggering immediately or backfilling; the
        # trigger overlap comes from the schedule's OWN policy.
        if ($trigger || @$backfills) {
            my $Patch = Temporalio::Core::Proto::resolve(
                'temporal.api.schedule.v1.SchedulePatch');
            my %patch;
            if ($trigger) {
                my $Trigger = Temporalio::Core::Proto::resolve(
                    'temporal.api.schedule.v1.TriggerImmediatelyRequest');
                $patch{trigger_immediately} = $Trigger->new({
                    overlap_policy => Temporalio::Schedule::Policy::overlap_enum(
                        $schedule->policy->overlap),
                });
            }
            if (@$backfills) {
                $patch{backfill_request} =
                    [ map { $_->_to_proto } @$backfills ];
            }
            $fields{initial_patch} = $Patch->new(\%patch);
        }

        if (defined $memo) {
            $fields{memo} = await $self->_encode_string_payload_map(
                'temporal.api.common.v1.Memo', $memo);
        }
        if (defined $sa) {
            $fields{search_attributes} = _coerce_search_attributes($sa);
        }

        my $Request = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.CreateScheduleRequest');

        try {
            await $self->_rpc_call('CreateSchedule', $Request->new(\%fields));
        }
        catch ($error) {
            # ALREADY_EXISTS on CreateSchedule re-maps to ScheduleAlreadyRunning
            # (spec section 25.3): the re-map happens here, not in the section
            # 7.5 table.
            if (_is_already_exists($error)) {
                Temporalio::Exception::ScheduleAlreadyRunning->throw(
                    message     => "schedule '$id' already exists",
                    schedule_id => $id,
                );
            }
            die $error;
        }
        return Temporalio::Client::ScheduleHandle->new(client => $self, id => $id);
    }

    # list_schedules($query, page_size => 1000) — returns a lazy async iterator
    # over Schedule::ListDescription records (spec section 25.1). No RPC until
    # the first ->next is awaited.
    method list_schedules ($query = undef, %opts) {
        Temporalio::Common::Options::assert_known_keys(
            'list_schedules', \%opts, { page_size => 1 });
        return Temporalio::Client::_ScheduleListIterator->new(
            client    => $self,
            query     => $query,
            # Python sends page_size 1000 when the caller omits it (finding
            # A17 / spec R69; ../sdk-python/temporalio/client/_client.py:2732);
            # the ListSchedulesRequest field is maximum_page_size.
            page_size => $opts{page_size} // 1000,
        );
    }

    # _build_start_workflow_request($workflow_or_string, \@args, %kwargs) —
    # async; maps the spec section 7.4 kwargs onto a
    # StartWorkflowExecutionRequest. Validation (required id/task_queue, policy
    # strings) happens here, before any RPC. Args/memo/header values encode
    # through the data converter.
    async method _build_start_workflow_request ($workflow, $args, %kwargs) {
        my $class = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.StartWorkflowExecutionRequest');
        return await $self->_populate_start_request($class, $workflow, $args,
            \%kwargs);
    }

    # _build_signal_with_start_workflow_request(...) — async; like the above
    # but targets SignalWithStartWorkflowExecutionRequest and additionally
    # carries the signal name + encoded signal args.
    async method _build_signal_with_start_workflow_request ($workflow, $args, %kwargs) {
        my $signal      = delete $kwargs{signal};
        my $signal_args = delete $kwargs{signal_args} // [];
        Temporalio::Exception::Argument->throw(
            message => 'signal_with_start_workflow requires a signal name')
            unless defined $signal && length $signal;

        # The generated proto accessors are read-only, so every field must be
        # passed through new(): collect the signal extras and hand them to the
        # shared populator to merge into the constructor args.
        my %extra = (signal_name => $signal);
        if (@$signal_args) {
            my @payloads = await $data_converter->to_payloads($signal_args);
            my $Payloads = Temporalio::Core::Proto::resolve(
                'temporal.api.common.v1.Payloads');
            $extra{signal_input} = $Payloads->new({ payloads => [@payloads] });
        }

        my $class = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.SignalWithStartWorkflowExecutionRequest');
        return await $self->_populate_start_request($class, $workflow,
            $args, \%kwargs, \%extra);
    }

    # The start_workflow/signal_with_start_workflow option contract. The
    # signal/signal_args pair is consumed by the SignalWithStart builder before
    # this set is checked.
    my %START_WORKFLOW_OPTION_KEYS = map { $_ => 1 } qw(
        id task_queue id_reuse_policy id_conflict_policy cron_schedule
        request_eager_start execution_timeout run_timeout task_timeout
        start_delay retry_policy priority search_attributes memo headers
        completion_callbacks links request_id
        static_summary static_details versioning_override
    );

    # Shared body for both request kinds. Mutates and returns a fresh request
    # message of $class. Async because args/memo/header encode through the
    # data converter.
    async method _populate_start_request ($class, $workflow, $args, $kwargs, $extra = {}) {
        # One strictness rule across the client surface (spec R44, finding
        # A10, shared with R35): an unknown option key raises the typed
        # argument error before any RPC.
        Temporalio::Common::Options::assert_known_keys(
            'start_workflow', $kwargs, \%START_WORKFLOW_OPTION_KEYS);
        my %k = %$kwargs;
        my $id         = delete $k{id};
        my $task_queue = delete $k{task_queue};
        Temporalio::Exception::Argument->throw(
            message => 'start_workflow requires an id')
            unless defined $id && length $id;
        Temporalio::Exception::Argument->throw(
            message => 'start_workflow requires a task_queue')
            unless defined $task_queue && length $task_queue;

        my $workflow_name = _workflow_name($workflow);

        my $reuse = _policy_enum('id_reuse_policy', delete $k{id_reuse_policy},
            \%ID_REUSE_POLICY);
        my $conflict = _policy_enum('id_conflict_policy',
            delete $k{id_conflict_policy}, \%ID_CONFLICT_POLICY);

        my $WorkflowType = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.WorkflowType');
        my $TaskQueue = Temporalio::Core::Proto::resolve(
            'temporal.api.taskqueue.v1.TaskQueue');

        my %fields = (
            namespace                   => $namespace,
            workflow_id                 => $id,
            workflow_type               => $WorkflowType->new({ name => $workflow_name }),
            task_queue                  => $TaskQueue->new({ name => $task_queue }),
            identity                    => $identity,
            request_id                  => _new_uuid(),
            workflow_id_reuse_policy    => $reuse,
            workflow_id_conflict_policy => $conflict,
        );

        if (defined(my $cron = delete $k{cron_schedule})) {
            $fields{cron_schedule} = $cron;
        }
        if (delete $k{request_eager_start}) {
            $fields{request_eager_execution} = 1;
        }

        for my $pair (
            [ execution_timeout => 'workflow_execution_timeout' ],
            [ run_timeout       => 'workflow_run_timeout' ],
            [ task_timeout      => 'workflow_task_timeout' ],
            [ start_delay       => 'workflow_start_delay' ],
        ) {
            my ($kw, $proto_field) = @$pair;
            my $seconds = delete $k{$kw};
            $fields{$proto_field} = _duration($seconds) if defined $seconds;
        }

        if (my $args_ref = $args) {
            if (@$args_ref) {
                my @payloads = await $data_converter->to_payloads($args_ref);
                my $Payloads = Temporalio::Core::Proto::resolve(
                    'temporal.api.common.v1.Payloads');
                $fields{input} = $Payloads->new({ payloads => [@payloads] });
            }
        }

        if (defined(my $retry_policy = delete $k{retry_policy})) {
            $fields{retry_policy} = $retry_policy->to_proto;
        }
        if (defined(my $priority = delete $k{priority})) {
            $fields{priority} = $priority->to_proto;
        }
        if (defined(my $sa = delete $k{search_attributes})) {
            $fields{search_attributes} = _coerce_search_attributes($sa);
        }
        if (defined(my $memo = delete $k{memo})) {
            $fields{memo} = await $self->_encode_string_payload_map(
                'temporal.api.common.v1.Memo', $memo);
        }
        if (defined(my $headers = delete $k{headers})) {
            $fields{header} = await $self->_encode_string_payload_map(
                'temporal.api.common.v1.Header', $headers);
        }

        # Nexus async completion (B13 #11, spec section 26.2): a
        # :WorkflowRunOperation backing-workflow start carries the caller's
        # completion callback(s) (so the server notifies the caller when this
        # workflow completes), the caller<->backing event links, and reuses the
        # Nexus request_id as the start idempotency key. The OperationContext
        # passes ready-built temporal.api.common.v1.{Callback,Link} protos; the
        # client just places them on the request. When a callback is attached we
        # also set on_conflict_options so an id-conflict (USE_EXISTING) still
        # wires the callback to the already-running workflow — MUST-match
        # sdk-python _impl _build_start_workflow_execution_request.
        if (defined(my $callbacks = delete $k{completion_callbacks})) {
            $fields{completion_callbacks} = $callbacks if @$callbacks;
        }
        if (defined(my $start_links = delete $k{links})) {
            $fields{links} = $start_links if @$start_links;
        }
        my $rid = delete $k{request_id};
        if (defined $rid && length $rid) {
            $fields{request_id} = $rid;
        }
        if ($fields{completion_callbacks}) {
            my $OnConflict = Temporalio::Core::Proto::resolve(
                'temporal.api.workflow.v1.OnConflictOptions');
            $fields{on_conflict_options} = $OnConflict->new({
                attach_request_id           => 1,
                attach_completion_callbacks => 1,
                attach_links                => 1,
            });
        }

        # static_summary/static_details -> the request user_metadata (spec
        # R37, finding A7): each encodes to a single Payload via the shared
        # converter helper, MUST-match sdk-python client/_helpers.py
        # _encode_user_metadata / _impl.py _build_start_workflow_execution.
        my $summary = delete $k{static_summary};
        my $details = delete $k{static_details};
        if (defined $summary || defined $details) {
            $fields{user_metadata} =
                await $data_converter->encode_user_metadata($summary, $details);
        }

        # versioning_override -> its proto field (spec R37): accepts a
        # Temporalio::Common::VersioningOverride (pinned / auto_upgrade);
        # anything else raises the typed error rather than being dropped.
        if (defined(my $override = delete $k{versioning_override})) {
            Temporalio::Exception::Argument->throw(
                message => 'versioning_override must be a '
                         . 'Temporalio::Common::VersioningOverride '
                         . '(->pinned or ->auto_upgrade)')
                unless Scalar::Util::blessed($override)
                    && $override->isa('Temporalio::Common::VersioningOverride');
            $fields{versioning_override} = $override->to_proto;
        }

        # Merge caller-supplied extras (e.g. signal_name/signal_input for the
        # SignalWithStart variant) — the generated proto accessors are
        # read-only, so everything must arrive via new().
        %fields = (%fields, %$extra);

        return $class->new(\%fields);
    }

    # Encode a { name => value } hashref into a temporal.api.common.v1.{Memo,
    # Header} message: each value becomes a single Payload via the data
    # converter, keyed by name in the proto's `fields` map.
    async method _encode_string_payload_map ($proto_name, $hashref) {
        my $Message = Temporalio::Core::Proto::resolve($proto_name);
        my %map;
        for my $key (sort keys %$hashref) {
            # A value already shaped as a Payload (as a context-propagation
            # client-outbound interceptor sets header values, matching the
            # sdk-python Str => Payload header contract) passes through untouched:
            # re-running it through the converter would double-encode it (#10
            # C-ICEPT-ACTIVITY-HEADERS GAP B). Raw values (the usual memo/header
            # case) encode exactly once. One contract, in
            # Temporalio::Interceptor::Headers.
            my $value = $hashref->{$key};
            if (Temporalio::Interceptor::Headers::is_payload($value)) {
                $map{$key} = $value;
                next;
            }
            my ($payload) = await $data_converter->to_payloads([ $value ]);
            $map{$key} = $payload;
        }
        return $Message->new({ fields => \%map });
    }

    # ----- non-method helpers (file-scope subs compile into main:: under a
    # bare `class`; keep them here so the methods above can call them) -----

    sub _workflow_name ($workflow) {
        # The archived v1 spec (section 7.4) promises the workflow argument
        # as "class name OR a workflow function ref" alongside the plain
        # type-name string; v0.1 shipped strings only (spec R63, finding
        # A8). Resolution is single-sourced in the definition side's
        # Temporalio::Workflow::Definition::resolve_workflow_type (the same
        # helper behind start_child_workflow / continue_as_new). The lazy
        # require keeps client-only string callers from loading the
        # definition layer (and its determinism-guard install) until a
        # non-string form actually arrives; a class-name string with
        # _workflow_type implies Definition.pm is already loaded.
        my $resolved;
        if (defined $workflow && !ref $workflow && length $workflow) {
            $resolved = $workflow->can('_workflow_type')
                ? Temporalio::Workflow::Definition::resolve_workflow_type($workflow)
                : $workflow;    # plain workflow-type string, verbatim
        }
        elsif (ref $workflow) {
            require Temporalio::Workflow::Definition;
            $resolved =
                Temporalio::Workflow::Definition::resolve_workflow_type($workflow);
        }
        Temporalio::Exception::Argument->throw(
            message => 'start_workflow requires a workflow type name '
                     . '(string), a workflow definition class, or its '
                     . 'workflow function ref')
            unless defined $resolved && !ref $resolved && length $resolved;
        return $resolved;
    }

    sub _policy_enum ($name, $value, $table) {
        return 0 unless defined $value;          # unspecified
        return $value if $value =~ /\A[0-9]+\z/; # already a proto number
        my $num = $table->{$value};
        Temporalio::Exception::Argument->throw(
            message => "invalid $name '$value' (expected one of "
                     . join(', ', sort keys %$table) . ')')
            unless defined $num;
        return $num;
    }

    sub _duration ($seconds) {
        my $Duration = Temporalio::Core::Proto::resolve(
            'google.protobuf.Duration');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Duration->new({ seconds => $whole, nanos => $nanos });
    }

    # True when the error is a server ALREADY_EXISTS (gRPC code 6). On
    # CreateSchedule the section 7.5 table maps this to a generic RpcError
    # carrying status_code 6 (the WorkflowAlreadyStarted special-case is keyed
    # on Start/SignalWithStartWorkflowExecution only).
    sub _is_already_exists ($error) {
        return 0 unless Scalar::Util::blessed($error);
        return 1 if $error->isa('Temporalio::Exception::WorkflowAlreadyStarted');
        return 0 unless $error->isa('Temporalio::Exception::RpcError');
        my $code = $error->can('status_code') ? $error->status_code : undef;
        return defined $code && $code == 6 ? 1 : 0;
    }

    sub _coerce_search_attributes ($sa) {
        return $sa->to_proto
            if Scalar::Util::blessed($sa)
            && $sa->isa('Temporalio::Common::TypedSearchAttributes');
        # A bare untyped hashref is forbidden (spec section 7.4 — no guessing).
        Temporalio::Exception::Argument->throw(
            message => 'search_attributes must be a '
                     . 'Temporalio::Common::TypedSearchAttributes instance '
                     . '(a bare untyped hashref is not accepted — spec 7.4)');
    }

    # Detect Data::UUID once at load time, NOT lazily on first call: the first
    # _new_uuid call now happens inside an async (Future::AsyncAwait) frame
    # (WorkflowHandle->cancel/signal), and a failed `require` there leaves $@
    # set in a way the async error-detection re-raises. `local $@` keeps the
    # probe self-contained regardless.
    my $HAVE_DATA_UUID = do { local $@; eval { require Data::UUID; 1 } ? 1 : 0 };

    # A v4-ish UUID for request_id. The server treats request_id as an opaque
    # idempotency token; any unique value works. Uses Data::UUID if present,
    # else a random fallback in canonical 8-4-4-4-12 form.
    sub _new_uuid () {
        my $have_uuid = $HAVE_DATA_UUID;
        if ($have_uuid) {
            return lc(Data::UUID->new->create_str);
        }
        my @h = map { sprintf '%04x', int(rand(0x10000)) } 1 .. 8;
        return sprintf '%s%s-%s-4%s-%x%s-%s%s%s',
            $h[0], $h[1], $h[2], substr($h[3], 1),
            (8 + int(rand(4))), substr($h[4], 1), $h[5], $h[6], $h[7];
    }

    # _rpc_call($rpc_name, $request_msg, %opts), async. The funnel every
    # high-level client method's RPC goes through: a thin delegator to
    # Connection::rpc_call (spec section 7.5; the funnel body moved there for
    # the raw service handles, spec R91 / parity audit client finding 1) that
    # flips the retry default to 1, because every high-level method wants
    # core's client RetryConfig applied. Callers pass the Connection::rpc_call
    # option set (service/retry/timeout/response_class/error_context).
    async method _rpc_call ($rpc, $request, %opts) {
        return await $connection->rpc_call($rpc, $request, retry => 1, %opts);
    }

    # Default client identity, "<pid>@<hostname>" (spec section 7.1;
    # convention verified against sdk-python service.py and sdk-ruby
    # client/connection.rb).
    sub default_identity ($class) {
        return $$ . '@' . Sys::Hostname::hostname();
    }

    # Coerce a config kwarg: undef/0 stays undef, a hashref becomes
    # $config_class->new(%$hashref), an instance passes through, anything
    # else raises Argument.
    sub _coerce_config ($name, $value, $config_class) {
        return undef unless $value;
        return $config_class->new if !ref $value;    # e.g. tls => 1
        return $config_class->new(%$value) if ref $value eq 'HASH';
        return $value
            if Scalar::Util::blessed($value) && $value->isa($config_class);
        Temporalio::Exception::Argument->throw(
            message => "$name must be a boolean, a hashref, or a"
                     . " $config_class instance");
    }

    # connect($target, %options) — async (spec section 7.1/7.3): validates
    # and builds everything synchronously (bad PEM and friends fail before
    # any RPC), then awaits temporal_core_client_connect via the callback
    # bridge and returns a connected client.
    async sub connect ($class, $target, %options) {
        Temporalio::Common::Options::assert_known_keys(
            'Temporalio::Client->connect', \%options,
            { runtime => 1, namespace => 1, api_key => 1, tls => 1,
              identity => 1, rpc_metadata => 1, retry => 1, keep_alive => 1,
              data_converter => 1, interceptors => 1, lazy => 1,
              http_connect_proxy => 1,
              default_workflow_query_reject_condition => 1 });
        my $runtime        = delete $options{runtime};
        my $namespace      = delete $options{namespace} // 'default';
        my $api_key        = delete $options{api_key};
        my $tls            = delete $options{tls};
        my $identity       = delete $options{identity}
                          // $class->default_identity;
        my $rpc_metadata   = delete $options{rpc_metadata};
        my $retry          = delete $options{retry};
        # Keep-alive defaults ON with the spec 7.2 defaults (matching the
        # reference SDKs); pass keep_alive => 0 to disable.
        my $keep_alive     = exists $options{keep_alive}
            ? delete $options{keep_alive}
            : {};
        my $data_converter = delete $options{data_converter}
                          // Temporalio::Converter::Data->new;
        my $interceptors   = delete $options{interceptors} // [];
        my $lazy           = delete $options{lazy} // 0;
        my $http_proxy     = delete $options{http_connect_proxy};
        # Spec R93 (parity audit client finding 4): the query-time fallback
        # reject condition, matching Python's connect kwarg
        # (_client.py:144-145,184-187). Stored on the client; resolved and
        # validated by the R67 map when a query omits reject_condition.
        my $default_query_reject =
            delete $options{default_workflow_query_reject_condition};

        Temporalio::Exception::Argument->throw(
            message => 'Temporalio::Client->connect requires a target'
                     . ' host:port')
            unless defined $target && length $target;

        $runtime //= Temporalio::Runtime->default;
        my $tls_config =
            _coerce_config(tls => $tls, 'Temporalio::Client::TlsConfig');
        my $retry_config =
            _coerce_config(retry => $retry, 'Temporalio::Client::RetryConfig')
            // Temporalio::Client::RetryConfig->new;
        my $keep_alive_config = _coerce_config(
            keep_alive => $keep_alive, 'Temporalio::Client::KeepAliveConfig');
        # http_connect_proxy: undef/0 -> no proxy; a hashref -> config (its
        # ADJUST enforces target_host + the auth xor); an instance passes
        # through. A bare truthy value (e.g. http_connect_proxy => 1) has no
        # target_host, so reject it with an Argument before any RPC (spec 30.2)
        # rather than letting `new` die on the missing required field.
        if (defined $http_proxy && !ref $http_proxy) {
            Temporalio::Exception::Argument->throw(
                message => 'http_connect_proxy requires a target_host (pass a'
                         . ' hashref { target_host => "host:port", ... } or a'
                         . ' Temporalio::Client::HttpConnectProxyConfig)');
        }
        my $http_proxy_config = _coerce_config(http_connect_proxy => $http_proxy,
            'Temporalio::Client::HttpConnectProxyConfig');

        # The bridge parses target_url as a URL; the scheme encodes the TLS
        # choice exactly as the reference SDKs do (sdk-python service.py).
        my $target_url = ($tls_config ? 'https' : 'http') . "://$target";

        # rpc_metadata entries are MetadataRef items, each "key\nvalue";
        # keys cannot contain newlines (per the header).
        my @metadata_entries;
        for my $key (sort keys %{ $rpc_metadata // {} }) {
            my $value = $rpc_metadata->{$key} // '';
            if ("$key$value" =~ /\n/) {
                Temporalio::Exception::Argument->throw(
                    message => 'rpc_metadata keys and values must not contain'
                             . " newlines (key '$key')");
            }
            push @metadata_entries, "$key\n$value";
        }

        # Build the TemporalCoreConnectionOptions record tree. @keep (and
        # the record itself, as a lexical across the await) must live until
        # the connect callback fires — client.rs: options must live through
        # the callback.
        my @keep;
        my sub ref_pair ($name, $value) {
            my ($data, $size) =
                Temporalio::Core::FFI::keep_buffer(\@keep, $value);
            return ("${name}_data" => $data, "${name}_size" => $size);
        }
        my ($metadata_data, $metadata_count) =
            Temporalio::Core::FFI::keep_byte_array_ref_array(
                \@keep, \@metadata_entries);

        my $options_record = Temporalio::Core::FFI::ConnectionOptions->new(
            ref_pair(target_url     => $target_url),
            ref_pair(client_name    => 'temporal-perl'),
            ref_pair(client_version => $Temporalio::SDK::VERSION),
            metadata_data        => $metadata_data,
            metadata_size        => $metadata_count,
            binary_metadata_data => undef,
            binary_metadata_size => 0,
            ref_pair(api_key  => $api_key),
            ref_pair(identity => $identity),
            tls_options        => $tls_config
                ? Temporalio::Core::FFI::keep_record(
                      \@keep, $tls_config->to_ffi(\@keep))
                : undef,
            retry_options      => Temporalio::Core::FFI::keep_record(
                \@keep, $retry_config->to_ffi(\@keep)),
            keep_alive_options => $keep_alive_config
                ? Temporalio::Core::FFI::keep_record(
                      \@keep, $keep_alive_config->to_ffi(\@keep))
                : undef,
            http_connect_proxy_options       => $http_proxy_config
                ? Temporalio::Core::FFI::keep_record(
                      \@keep, $http_proxy_config->to_ffi(\@keep))
                : undef,
            grpc_override_callback           => undef,
            grpc_override_callback_user_data => undef,
            dns_load_balancing_options       => undef,
        );

        # The core connect, wrapped in a closure so a lazy client can defer
        # it to the first RPC (spec R90; parity audit client finding 3,
        # matching sdk-python _client.py:151,205-207 / service.py
        # _BridgeServiceClient). The closure keeps $options_record and @keep
        # alive until the connect callback fires. Spec section 7.3 step 5: a
        # non-null fail byte array (surfaced by the callback layer as
        # Exception::Bridge) becomes RpcError with the decoded message —
        # from connect() itself on the eager path, from the first RPC on
        # the lazy path.
        my $do_connect = async sub {
            # Anchor the kept buffers: a closure only captures what it
            # references, and $options_record points INTO @keep, so without
            # this the buffers are freed when connect() returns on the lazy
            # path and the deferred connect reads dangling memory (observed
            # as "Invalid options: relative URL without a base").
            my $keep_anchor = \@keep;
            my $connection_ptr;
            try {
                $connection_ptr = await Temporalio::Core::Callback->issue_async(
                    $runtime, connect => sub ($user_data, $trampoline) {
                        Temporalio::Core::FFI::client_connect(
                            $runtime->core_ptr, $options_record,
                            $user_data, $trampoline);
                    });
            }
            catch ($error) {
                if (Scalar::Util::blessed($error)
                    && $error->isa('Temporalio::Exception::Bridge'))
                {
                    Temporalio::Exception::RpcError->throw(
                        message => $error->message);
                }
                die $error;
            }
            return $connection_ptr;
        };

        my $connection;
        if ($lazy) {
            # Deferred: no connect attempt here. Connection->connected_ptr
            # runs $do_connect on the first RPC, behind a once-init guard
            # shared by concurrent first RPCs.
            $connection = Temporalio::Client::Connection->new(
                runtime => $runtime,
                connect => $do_connect,
            );
        }
        else {
            # Eager (the default): connect now, fail now.
            my $connection_ptr = await $do_connect->();
            $connection = Temporalio::Client::Connection->new(
                runtime => $runtime,
                ptr     => $connection_ptr,
            );
        }

        return $class->new(
            connection     => $connection,
            namespace      => $namespace,
            identity       => $identity,
            data_converter => $data_converter,
            runtime        => $runtime,
            interceptors   => $interceptors,
            default_workflow_query_reject_condition => $default_query_reject,
        );
    }
}


1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client - client for a Temporal server

=head1 SYNOPSIS

    use Temporalio::Client;

    my $client = await Temporalio::Client->connect(
        'localhost:7233',                  # positional, required
        namespace    => 'default',
        api_key      => $token,            # rotate via update_api_key
        tls          => 1 | { ... } | Temporalio::Client::TlsConfig->new(...),
        identity     => "$$\@$hostname",   # default: "<pid>@<hostname>"
        rpc_metadata => { 'x-extra' => 'foo' },
        retry        => { ... } | Temporalio::Client::RetryConfig->new(...),
        keep_alive   => { interval => 30, timeout => 15 },
        data_converter => $converter,      # default Temporalio::Converter::Data->new
        runtime      => $rt,               # default Temporalio::Runtime->default
    );

    $client->update_api_key($new_token);

=head1 DESCRIPTION

The Temporal client (spec section 7). C<connect> is async: it resolves the
runtime, validates and builds the C<TemporalCoreConnectionOptions> tree
synchronously — TLS PEM material is detected (content vs path) and slurped
before the async call, so a bad PEM raises
L<Temporalio::Exception::Argument> before any RPC — then awaits
C<temporal_core_client_connect> through the callback bridge. On failure it
raises L<Temporalio::Exception::RpcError> with the decoded bridge message.
On success it returns a client holding the
L<Temporalio::Client::Connection>, namespace, identity, data converter,
and runtime.

C<tls>, C<retry>, and C<keep_alive> each accept a boolean, a hashref of
constructor arguments, or a config instance (L<Temporalio::Client::TlsConfig>,
L<Temporalio::Client::RetryConfig>, L<Temporalio::Client::KeepAliveConfig>).
Retry defaults match sdk-core exactly and retries run inside sdk-core, not
the Perl layer. Keep-alive defaults on (30s/15s); disable with
C<< keep_alive => 0 >>. C<update_api_key> rotates the bearer token on the
live connection synchronously; rotation is always manual (spec section
7.3). Connections are established eagerly by default, inside C<connect>
itself; C<< lazy => 1 >> defers the core connection to the first RPC
(spec R90, see L</connect>).

Every client RPC funnels through the private C<_rpc_call> helper, a thin
wrapper over L<Temporalio::Client::Connection>'s C<rpc_call> with C<retry>
set by default (retries run inside sdk-core against the client retry
config): the funnel encodes the request proto, calls
C<temporal_core_client_rpc_call> over the callback bridge, decodes the
typed response, and maps failures onto the exception hierarchy via the
spec section 7.5 MUST-match table in L<Temporalio::Core::Callback>.

RPCs the high-level client does not wrap remain reachable through the raw
service handles (spec R91): C<workflow_service> and C<operator_service>
return L<Temporalio::Client::WorkflowService> and
L<Temporalio::Client::OperatorService> handles whose per-rpc methods are
generated from the vendored proto service descriptors.

Workflow operations (C<start_workflow> and friends, spec section 7.4) are
documented under L</METHODS>.

=head2 Option strictness

Every public method on the client surface (this class and the handle classes
it returns) rejects unknown option keys through the shared
L<Temporalio::Common::Options> validator, raising a
L<Temporalio::Exception::Argument> that names the offending key and the known
set (spec R44). A mistyped option never vanishes silently and never reaches
an RPC.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Client->new(
        connection => ...,
        namespace => ...,
        identity => ...,
        data_converter => ...,
        runtime => ...,
    );

Constructs a Temporalio::Client. Named parameters:

=over 4

=item C<connection>

(required)

=item C<namespace>

(required)

=item C<identity>

(required)

=item C<data_converter>

(required)

=item C<runtime>

(required)

=item C<default_workflow_query_reject_condition>

(optional; default none) The query-time fallback reject condition; see
L</connect>.

=back

=head1 METHODS

=head2 connect

    my $client = await Temporalio::Client->connect(
        'localhost:7233',            # target host:port, positional, required
        namespace => 'default',
    );

Class method (async): connects to a Temporal server at the given
C<host:port> target and returns a L<Future> resolving to a new client.
Named options (spec R66; each entry states its type and default):

=over 4

=item C<namespace>

(string; default C<'default'>) The namespace every workflow, schedule, and
visibility call made through this client addresses.

=item C<api_key>

(string; default none) Bearer token sent as gRPC metadata on every RPC.
Rotate it later with L</update_api_key>.

=item C<tls>

(boolean, hashref, or L<Temporalio::Client::TlsConfig>; default off) TLS
configuration. A bare true value enables TLS with defaults; a hashref is
passed to the config constructor. PEM material (content or path) is
validated and slurped before any RPC.

=item C<identity>

(string; default C<< <pid>@<hostname> >>) The client identity reported to
the server.

=item C<rpc_metadata>

(hashref of string to string; default none) Extra gRPC metadata headers
sent on every RPC. Keys and values must not contain newlines.

=item C<retry>

(hashref or L<Temporalio::Client::RetryConfig>; default the sdk-core retry
defaults) Per-call retry policy; retries run inside sdk-core, not the Perl
layer.

=item C<keep_alive>

(boolean, hashref, or L<Temporalio::Client::KeepAliveConfig>; default on
with a 30s interval and 15s timeout) HTTP/2 keep-alive. Pass
C<< keep_alive => 0 >> to disable.

=item C<data_converter>

(L<Temporalio::Converter::Data>; default
C<< Temporalio::Converter::Data->new >>) The payload, failure, and codec
conversion pipeline.

=item C<default_workflow_query_reject_condition>

(string or proto enum number; default none) The default rejection condition
for workflow queries when the per-call C<reject_condition> is not given to
C<< WorkflowHandle->query >> (spec R93; Python SDK parity, C<_client.py>).
Accepts the same values as the per-call option: C<'none'>, C<'not_open'>,
C<'not_completed_cleanly'>, or a raw
C<temporal.api.enums.v1.QueryRejectCondition> number. A per-call value
overrides it; an unknown name raises L<Temporalio::Exception::Argument> from
the query, before any RPC.

=item C<interceptors>

(arrayref of interceptor instances; default C<[]>) The outbound interceptor
chain, first-listed outermost (spec section 27). A worker built on this
client inherits the list and appends its own.

=item C<lazy>

(boolean; default 0) When true, C<connect> validates its options and
returns the client without connecting: the core gRPC connection is
deferred to the first RPC, and concurrent first RPCs share the single
in-flight connect (spec R90; Python SDK parity, C<_client.py>). A connect
failure then surfaces from that first call as
L<Temporalio::Exception::RpcError>, and the next RPC retries the connect.
Until the client has connected, building a worker on it and
C<update_api_key> both raise L<Temporalio::Exception::Runtime>. When
false (the default) the connection is established eagerly, inside
C<connect> itself.

=item C<http_connect_proxy>

(hashref or L<Temporalio::Client::HttpConnectProxyConfig>; default none)
Routes the connection through an HTTP CONNECT proxy. Requires
C<target_host>; C<basic_auth_user> and C<basic_auth_pass> are optional and
must be given together.

=item C<runtime>

(L<Temporalio::Runtime>; default C<< Temporalio::Runtime->default >>) The
runtime whose IO::Async loop and core runtime back this client.

=back

=head2 connection

Accessor returning the C<connection> value.

=head2 count_workflows

Async. Returns a L<Future> resolving to the count of executions matching the given visibility query.

=head2 create_schedule

Async. Creates a schedule and returns a L<Future> resolving to a L<Temporalio::Client::ScheduleHandle>. Validates the limited/remaining-actions invariant before any RPC, builds an C<initial_patch> only when C<trigger_immediately> or a backfill list is given, and re-maps a server C<ALREADY_EXISTS> to L<Temporalio::Exception::ScheduleAlreadyRunning>.
The backfill list is accepted under either kwarg form: C<backfills> (the shipped plural, matching the Ruby SDK) or C<backfill> (matching the Python SDK, finding A17 / spec R69); passing both raises the typed argument error.

=head2 get_schedule_handle

Returns a L<Temporalio::Client::ScheduleHandle> for an existing schedule id without making an RPC.

=head2 list_schedules

Returns a lazy L<Temporalio::Client::_ScheduleListIterator> over schedules matching the given visibility query; no RPC is made until the first C<next> is awaited.
Pages are C<page_size> rows each (default 1000, as in the Python SDK).

=head2 async_activity_handle

    my $h = $client->async_activity_handle(task_token => $bytes);
    my $h = $client->async_activity_handle(
        workflow_id => $w, run_id => $r, activity_id => $a);

Returns a L<Temporalio::Client::AsyncActivityHandle> for an activity completing
out of band (spec section 22), addressed by an opaque task token or an id
reference (C<workflow_id> + optional C<run_id> + C<activity_id>). The two forms
are mutually exclusive; C<workflow_id> requires C<activity_id>. No RPC is made.
Invalid combinations raise L<Temporalio::Exception::Argument>.

=head2 data_converter

Accessor returning the C<data_converter> value.

=head2 default_identity

Class method returning the default client identity string (C<pid@hostname>) used when none is supplied.

=head2 default_workflow_query_reject_condition

Accessor returning the connect-level default query reject condition (or
C<undef> when none was given). Applied by C<< WorkflowHandle->query >> when
the per-call C<reject_condition> is omitted (spec R93).

=head2 execute_workflow

Async. Starts a workflow and awaits its result in one call, returning a L<Future> that resolves to the workflow's return value.

=head2 get_workflow_handle

Returns a L<Temporalio::Client::WorkflowHandle> for an existing workflow id (optionally pinned to a run id) without making an RPC.

=head2 identity

Accessor returning the C<identity> value.

=head2 list_workflows

    my $iter = $client->list_workflows($query, page_size => 100);
    while (defined(my $info = await $iter->next)) { ... }

Synchronous: returns an iterator object at once, without an RPC. The
iterator's public contract is a single async method, C<next>. Each
C<< await $iter->next >> yields one
C<temporal.api.workflow.v1.WorkflowExecutionInfo> proto message for an
execution matching the given visibility query, then C<undef> once every
page is exhausted. Pages of the C<ListWorkflowExecutions> RPC are fetched
lazily (C<page_size> rows per page, default 1000 as in the Python SDK), so
the first RPC happens when the first C<next> is awaited. The iterator's
class name is private; rely on the C<next> contract described here (spec
R64).

=head2 namespace

Accessor returning the C<namespace> value.

=head2 reset_workflow

    my $new_run_id = await $client->reset_workflow($workflow_id, $run_id, %kwargs);

Async. Resets a workflow execution to an earlier workflow task and returns
the new run id (spec section 30.1). A thin convenience over the raw
C<ResetWorkflowExecution> RPC; delegates to
L<Temporalio::Client::WorkflowHandle/reset>. C<workflow_task_finish_event_id>
is required; see C<reset> for the accepted kwargs.

=head2 runtime

Accessor returning the C<runtime> value.

=head2 interceptors

Accessor returning the ordered interceptor list passed to C<connect> (spec
section 27). The first-listed interceptor is outermost; the worker inherits this
list and appends its own.

=head2 signal_with_start_workflow

Async. Atomically signals a workflow, starting it first if it is not already running; returns a L<Future> resolving to a workflow handle.

=head2 start_workflow

Async. Starts a workflow execution and returns a L<Future> resolving to a L<Temporalio::Client::WorkflowHandle>.

The first argument names the workflow (spec R63): a plain workflow type-name
string, a L<Temporalio::Workflow::Definition> subclass name (resolving to its
C<:Run> type), or that class's workflow function ref (the C<:Run> method
ref). Anything unresolvable raises L<Temporalio::Exception::Argument> before
any RPC.

C<static_summary> and C<static_details> (fixed single-line summary and
multi-line details shown in the UI) encode through the data converter into
the request's user-metadata payloads (spec R37). C<versioning_override>
takes a L<Temporalio::Common::VersioningOverride> (C<< ->pinned >> or
C<< ->auto_upgrade >>); any other value raises
L<Temporalio::Exception::Argument>.

=head2 update_api_key

Updates the API key sent on subsequent RPCs for this client's connection.

=head2 workflow_service

Returns a L<Temporalio::Client::WorkflowService> raw service handle: the
low-level escape hatch over the full WorkflowService RPC surface (spec R91;
Python C<_client.py:311-314> parity). Calls made through it are single-shot
by default (no core retry) and bypass the high-level client's interceptors
and converters.

=head2 operator_service

Returns a L<Temporalio::Client::OperatorService> raw service handle over the
OperatorService RPC surface, e.g. search-attribute management (spec R91;
Python C<_client.py:316-318> parity). Same raw-call semantics as
L</workflow_service>.

=cut
