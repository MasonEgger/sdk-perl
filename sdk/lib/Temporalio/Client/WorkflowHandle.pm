# ABOUTME: Handle to a started/identified workflow (spec section 7.6): result()
# ABOUTME: long-polls history and maps the terminal event, plus describe/cancel/
# ABOUTME: terminate/signal/query/fetch_history_events over the client RPC path.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Client::Interceptor ();
use Temporalio::Client::HistoryEventIterator ();
use Temporalio::Common::Options ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Cancelled ();
use Temporalio::Exception::Server ();
use Temporalio::Exception::Terminated ();
use Temporalio::Exception::Timeout ();
use Temporalio::Exception::WorkflowContinuedAsNew ();
use Temporalio::Exception::WorkflowFailure ();

class Temporalio::Client::WorkflowHandle {
    # temporal.api.enums.v1.HistoryEventFilterType (introspected from the
    # vendored proto): CLOSE_EVENT == 2. result() long-polls with this filter
    # so the server returns only the single terminal event (spec section 7.6).
    my $CLOSE_EVENT = 2;

    field $client                 :param;
    field $workflow_id            :param;
    field $run_id                 :param = undef;
    field $first_execution_run_id :param = undef;
    field $result_run_id          :param = undef;

    # Eager start (spec section 23.1, detect-only): true when the
    # StartWorkflowExecutionResponse carried an eager_workflow_task (the server
    # returned the first workflow task for the shared core client to execute
    # in-process). Read-only — the lang layer never routes the embedded task;
    # the Rust core owns that dispatch. False when eager start was not requested
    # or the server has it disabled.
    field $eagerly_started        :param = 0;

    # Explicit readers (field :reader needs perl 5.40+; floor is 5.38).
    method client                 { $client }
    method workflow_id            { $workflow_id }
    method run_id                 { $run_id }
    method first_execution_run_id { $first_execution_run_id }
    method result_run_id          { $result_run_id }
    method eagerly_started        { $eagerly_started }

    # result(follow_runs => 1, ...) — async (spec section 7.6, MUST match the
    # reference SDK terminal-event decision table — verified against sdk-python
    # client/_workflow.py WorkflowHandle.result lines 186-316). Long-polls
    # GetWorkflowExecutionHistory with the CLOSE_EVENT filter on the current
    # run id; the single returned event is the terminal event, mapped here.
    async method result (%opts) {
        # One strictness rule across the client surface (spec R44, finding
        # A10): the audit's defect was exactly result(follow_run => 0), a typo
        # that silently followed continue-as-new. Unknown keys raise the typed
        # argument error before any RPC; same contract for every public method
        # in this class.
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->result', \%opts, { follow_runs => 1 });
        my $follow_runs = exists $opts{follow_runs} ? $opts{follow_runs} : 1;

        # Base the result on result_run_id if present, else the handle run id
        # (sdk-python uses _result_run_id which falls back to the run id).
        my $hist_run_id = $result_run_id // $run_id;

        while (1) {
            my $followed_run_id;
            my $iter = $self->_history_iterator(
                $hist_run_id,
                wait_new_event    => 1,
                event_filter_type => $CLOSE_EVENT,
                skip_archival     => 1,
            );

            while (defined(my $event = await $iter->next)) {
                my $which = $event->which_attributes // '';

                if ($which eq 'workflow_execution_completed_event_attributes') {
                    my $attr = $event->workflow_execution_completed_event_attributes;
                    if ($follow_runs && length($attr->new_execution_run_id // '')) {
                        $followed_run_id = $attr->new_execution_run_id;
                        last;
                    }
                    return await $self->_decode_first_payload($attr->result);
                }
                elsif ($which eq 'workflow_execution_failed_event_attributes') {
                    my $attr = $event->workflow_execution_failed_event_attributes;
                    if ($follow_runs && length($attr->new_execution_run_id // '')) {
                        $followed_run_id = $attr->new_execution_run_id;
                        last;
                    }
                    my $cause =
                        await $client->data_converter->from_failure($attr->failure);
                    Temporalio::Exception::WorkflowFailure->throw(
                        message => 'Workflow execution failed',
                        cause   => $cause,
                    );
                }
                elsif ($which eq 'workflow_execution_timed_out_event_attributes') {
                    my $attr = $event->workflow_execution_timed_out_event_attributes;
                    if ($follow_runs && length($attr->new_execution_run_id // '')) {
                        $followed_run_id = $attr->new_execution_run_id;
                        last;
                    }
                    Temporalio::Exception::WorkflowFailure->throw(
                        message => 'Workflow execution timed out',
                        cause   => Temporalio::Exception::Timeout->new(
                            message => 'Workflow timed out'),
                    );
                }
                elsif ($which eq 'workflow_execution_canceled_event_attributes') {
                    my $attr = $event->workflow_execution_canceled_event_attributes;
                    my $details =
                        await $self->_decode_all_payloads($attr->details);
                    Temporalio::Exception::WorkflowFailure->throw(
                        message => 'Workflow execution cancelled',
                        cause   => Temporalio::Exception::Cancelled->new(
                            message => 'Workflow cancelled',
                            details => $details,
                        ),
                    );
                }
                elsif ($which eq 'workflow_execution_terminated_event_attributes') {
                    my $attr   = $event->workflow_execution_terminated_event_attributes;
                    my $reason = $attr->reason;
                    Temporalio::Exception::WorkflowFailure->throw(
                        message => 'Workflow execution terminated',
                        cause   => Temporalio::Exception::Terminated->new(
                            message => (defined $reason && length $reason)
                                ? $reason : 'Workflow terminated',
                            reason  => $reason,
                        ),
                    );
                }
                elsif ($which eq 'workflow_execution_continued_as_new_event_attributes') {
                    my $attr = $event->workflow_execution_continued_as_new_event_attributes;
                    my $new_run = $attr->new_execution_run_id;
                    Temporalio::Exception::Server->throw(
                        message => 'Missing new run id on continue-as-new')
                        unless defined $new_run && length $new_run;
                    if ($follow_runs) {
                        $followed_run_id = $new_run;
                        last;
                    }
                    Temporalio::Exception::WorkflowContinuedAsNew->throw(
                        message    => 'Workflow continued as new',
                        new_run_id => $new_run,
                    );
                }
                # Any other event under a CLOSE_EVENT filter is unexpected; keep
                # draining the (single-event) page and loop again.
            }

            # We only reach here by `last` (a run we now follow) or by an empty
            # page. With a followed run id, loop on the new run; otherwise it is
            # an error — no terminal event was produced.
            if (defined $followed_run_id) {
                $hist_run_id = $followed_run_id;
                next;
            }
            Temporalio::Exception::Server->throw(
                message => 'No workflow completion event found');
        }
    }

    # describe(...) — async (spec section 7.6). Returns the decoded
    # DescribeWorkflowExecutionResponse, whose workflow_execution_info carries
    # the populated execution record. Verified against sdk-python _impl.py
    # describe_workflow (lines 361-384).
    async method describe (%opts) {
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->describe', \%opts, {});
        my $request = _resolve(
            'temporal.api.workflowservice.v1.DescribeWorkflowExecutionRequest')
            ->new({
                namespace => $client->namespace,
                execution => $self->_execution_message,
            });
        return await $client->_rpc_call('DescribeWorkflowExecution', $request);
    }

    # cancel(...) — async (spec section 7.6 / sdk-python _impl.py
    # cancel_workflow 344-359). Issues RequestCancelWorkflowExecution against
    # the run, threading first_execution_run_id so the run chain is honored.
    async method cancel (%opts) {
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->cancel', \%opts, { reason => 1 });
        my $reason = $opts{reason};
        my %fields = (
            namespace          => $client->namespace,
            workflow_execution => $self->_execution_message,
            identity           => $client->identity,
            request_id         => Temporalio::Client::_new_uuid(),
            first_execution_run_id => $first_execution_run_id // '',
        );
        $fields{reason} = $reason if defined $reason && length $reason;
        my $request = _resolve(
            'temporal.api.workflowservice.v1.RequestCancelWorkflowExecutionRequest')
            ->new(\%fields);
        await $client->_rpc_call('RequestCancelWorkflowExecution', $request);
        return;
    }

    # terminate(reason => ..., details => [...], ...) — async (spec section 7.6
    # / sdk-python _impl.py terminate_workflow 506-534). Encodes details via the
    # data converter and threads first_execution_run_id.
    async method terminate (%opts) {
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->terminate', \%opts,
            { reason => 1, details => 1 });
        my $reason  = $opts{reason};
        my $details = $opts{details} // [];
        my %fields = (
            namespace          => $client->namespace,
            workflow_execution => $self->_execution_message,
            identity           => $client->identity,
            first_execution_run_id => $first_execution_run_id // '',
        );
        $fields{reason} = $reason if defined $reason && length $reason;
        if (@$details) {
            $fields{details} = await $self->_encode_payloads($details);
        }
        my $request = _resolve(
            'temporal.api.workflowservice.v1.TerminateWorkflowExecutionRequest')
            ->new(\%fields);
        await $client->_rpc_call('TerminateWorkflowExecution', $request);
        return;
    }

    # temporal.api.enums.v1 reapply enums (enums/v1/reset.proto). No reference
    # SDK ships a high-level reset helper; these mirror the proto enum values
    # directly (the proto is the oracle, spec section 30.1).
    my %RESET_REAPPLY_TYPE = (
        signal       => 1,    # RESET_REAPPLY_TYPE_SIGNAL
        none         => 2,    # RESET_REAPPLY_TYPE_NONE
        all_eligible => 3,    # RESET_REAPPLY_TYPE_ALL_ELIGIBLE
    );
    my %RESET_REAPPLY_EXCLUDE_TYPE = (
        signal => 1,          # RESET_REAPPLY_EXCLUDE_TYPE_SIGNAL
        update => 2,          # RESET_REAPPLY_EXCLUDE_TYPE_UPDATE
        nexus  => 3,          # RESET_REAPPLY_EXCLUDE_TYPE_NEXUS
    );

    # Shared name-to-proto-enum validator for every named-value option on this
    # handle (the reapply maps above, the query reject map below; spec R67,
    # finding A13): a raw proto number passes through; an unknown name raises
    # the typed Argument error before any RPC.
    sub _named_enum ($name, $value, $table) {
        return $value if $value =~ /\A[0-9]+\z/;    # already a proto number
        my $num = $table->{$value};
        Temporalio::Exception::Argument->throw(
            message => "invalid $name '$value' (expected one of "
                     . join(', ', sort keys %$table) . ')')
            unless defined $num;
        return $num;
    }

    # _build_reset_request(%kwargs) — builds a ResetWorkflowExecutionRequest
    # (spec section 30.1) without issuing any RPC, so it is unit-testable.
    # workflow_task_finish_event_id is required; a missing id or a bad reapply
    # enum string raises Argument before any RPC. request_id defaults to a fresh
    # UUID. reset_reapply_type (deprecated proto field) maps signal|none|
    # all_eligible; reset_reapply_exclude_types maps signal|update|nexus.
    method _build_reset_request (%kwargs) {
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->reset', \%kwargs,
            { workflow_task_finish_event_id => 1, reason => 1,
              reset_reapply_type => 1, reset_reapply_exclude_types => 1,
              request_id => 1 });
        my $finish_event_id = $kwargs{workflow_task_finish_event_id};
        Temporalio::Exception::Argument->throw(
            message => 'reset requires a workflow_task_finish_event_id'
                     . ' (the WORKFLOW_TASK_COMPLETED/TIMED_OUT/FAILED/STARTED'
                     . ' event to reset to)')
            unless defined $finish_event_id && $finish_event_id =~ /\A[0-9]+\z/;

        my %fields = (
            namespace          => $client->namespace,
            workflow_execution => $self->_execution_message,
            reason             => $kwargs{reason} // '',
            workflow_task_finish_event_id => $finish_event_id,
            request_id         => $kwargs{request_id}
                              // Temporalio::Client::_new_uuid(),
            identity           => $client->identity,
        );

        if (defined(my $type = $kwargs{reset_reapply_type})) {
            $fields{reset_reapply_type} =
                _named_enum('reset_reapply_type', $type,
                    \%RESET_REAPPLY_TYPE);
        }

        my $request = _resolve(
            'temporal.api.workflowservice.v1.ResetWorkflowExecutionRequest')
            ->new(\%fields);

        # A repeated enum value cannot be passed through new() — the generated
        # constructor type-checks every field as a scalar (a Protobuf-dist quirk
        # where new() validates repeated enums as singular). The set_ accessor
        # stores a repeated value verbatim, so apply the mapped exclude list
        # after construction.
        if (defined(my $exclude = $kwargs{reset_reapply_exclude_types})) {
            $request->set_reset_reapply_exclude_types([
                map { _named_enum('reset_reapply_exclude_types', $_,
                        \%RESET_REAPPLY_EXCLUDE_TYPE) } @$exclude
            ]);
        }

        return $request;
    }

    # reset(%kwargs) — async (spec section 30.1): a thin, clearly-forked
    # convenience helper (no reference SDK ships one) that funnels a
    # ResetWorkflowExecutionRequest through the client RPC path and returns the
    # new run id. The current run is terminated and a new run started.
    async method reset (%kwargs) {
        my $request = $self->_build_reset_request(%kwargs);
        my $response =
            await $client->_rpc_call('ResetWorkflowExecution', $request);
        return $response->run_id;
    }

    # signal($name, \@args, ...) — async (spec section 7.6 / sdk-python _impl.py
    # signal_workflow 474-504).
    async method signal ($name, $args = [], %opts) {
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->signal', \%opts, { headers => 1 });
        Temporalio::Exception::Argument->throw(
            message => 'signal requires a signal name (string)')
            unless defined $name && !ref $name && length $name;
        my $headers = delete $opts{headers} // {};
        my $input =
            Temporalio::Client::Interceptor::Input::SignalWorkflow->new(
                signal  => $name,
                args    => [ @$args ],
                headers => { %$headers },
                id      => $workflow_id,
                run_id  => $run_id,
                _root   => async sub ($in) { await $self->_root_signal($in) },
            );
        return await $client->_outbound->signal_workflow($input);
    }

    async method _root_signal ($input) {
        my $name = $input->get('signal');
        my %fields = (
            namespace          => $client->namespace,
            workflow_execution => $self->_execution_message,
            signal_name        => $name,
            identity           => $client->identity,
            request_id         => Temporalio::Client::_new_uuid(),
        );
        my $args = $input->args;
        if (@$args) {
            $fields{input} = await $self->_encode_payloads($args);
        }
        my $request = _resolve(
            'temporal.api.workflowservice.v1.SignalWorkflowExecutionRequest')
            ->new(\%fields);
        await $client->_rpc_call('SignalWorkflowExecution', $request);
        return;
    }

    # temporal.api.enums.v1.QueryRejectCondition (enums/v1/query.proto), spec
    # R67 (finding A13): reject_condition used to pass verbatim into the proto
    # enum. Names are Python-parity (sdk-python common.py
    # QueryRejectCondition: NONE/NOT_OPEN/NOT_COMPLETED_CLEANLY).
    my %QUERY_REJECT_CONDITION = (
        none                  => 1,    # QUERY_REJECT_CONDITION_NONE
        not_open              => 2,    # QUERY_REJECT_CONDITION_NOT_OPEN
        not_completed_cleanly => 3,    # ..._NOT_COMPLETED_CLEANLY
    );

    # _effective_query_reject_condition($per_call) — the single resolution
    # point for every query path (spec R93 / parity audit client finding 4):
    # a defined per-call value wins, else the connect-level default stored on
    # the client (Python _client.py:144-145,184-187 / _workflow.py:600-601).
    # The winner maps through the R67 name-to-enum table above (finding A13),
    # so a raw proto number passes through and an unknown name raises the
    # typed Argument error pre-RPC. Returns undef when neither is set,
    # leaving the proto field unset.
    method _effective_query_reject_condition ($per_call) {
        my $rc = $per_call // $client->default_workflow_query_reject_condition;
        return undef unless defined $rc;
        return _named_enum('reject_condition', $rc,
            \%QUERY_REJECT_CONDITION);
    }

    # query($name, \@args, reject_condition => ..., ...) — async (spec section
    # 7.6 / sdk-python _impl.py query_workflow 411-472). Returns the decoded
    # single query result; a server-rejected query raises QueryRejected.
    async method query ($name, $args = [], %opts) {
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->query', \%opts,
            { headers => 1, reject_condition => 1 });
        Temporalio::Exception::Argument->throw(
            message => 'query requires a query name (string)')
            unless defined $name && !ref $name && length $name;
        my $headers = delete $opts{headers} // {};
        my $input =
            Temporalio::Client::Interceptor::Input::QueryWorkflow->new(
                query   => $name,
                args    => [ @$args ],
                headers => { %$headers },
                id      => $workflow_id,
                run_id  => $run_id,
                opts    => { %opts },
                _root   => async sub ($in) { await $self->_root_query($in) },
            );
        return await $client->_outbound->query_workflow($input);
    }

    async method _root_query ($input) {
        my $name = $input->get('query');
        my $args = $input->args;
        my %opts = %{ $input->get('opts') // {} };

        my $WorkflowQuery =
            _resolve('temporal.api.query.v1.WorkflowQuery');
        my %query_fields = (query_type => $name);
        if (@$args) {
            $query_fields{query_args} = await $self->_encode_payloads($args);
        }
        my %fields = (
            namespace => $client->namespace,
            execution => $self->_execution_message,
            query     => $WorkflowQuery->new(\%query_fields),
        );
        # Per-call-or-client-default resolution, all in the shared helper
        # (spec R93 / parity audit client finding 4).
        if (defined(my $rc = $self->_effective_query_reject_condition(
                $opts{reject_condition}))) {
            $fields{query_reject_condition} = $rc;
        }
        my $request = _resolve(
            'temporal.api.workflowservice.v1.QueryWorkflowRequest')
            ->new(\%fields);
        my $response =
            await $client->_rpc_call('QueryWorkflow', $request);

        if (defined(my $rejected = $response->query_rejected)) {
            require Temporalio::Exception::QueryRejected;
            Temporalio::Exception::QueryRejected->throw(
                message => 'Query rejected (workflow status '
                         . ($rejected->status // 0) . ')');
        }
        return await $self->_decode_first_payload($response->query_result);
    }

    # temporal.api.enums.v1.UpdateWorkflowExecutionLifecycleStage (spec section
    # 19.2): ADMITTED == 1, ACCEPTED == 2, COMPLETED == 3. The supported
    # wait_for_stage strings map to ACCEPTED/COMPLETED; 'admitted' is rejected
    # with Argument (not a supported wait stage).
    my %WAIT_STAGE = (
        accepted  => 2,
        completed => 3,
    );

    # execute_update($name, \@args, %opts) — async (spec section 19.1). Sugar
    # over start_update + ->result: starts the update, waits for it to
    # complete, and returns the decoded result (or raises
    # Temporalio::Exception::WorkflowUpdateFailed on a failed outcome).
    # wait_for_stage defaults to 'completed' as in Python, whose
    # execute_update takes no wait_for_stage kwarg at all and hard-codes
    # WorkflowUpdateStage.COMPLETED (../sdk-python/temporalio/client/
    # _workflow.py:792-836, :830). This surface funnels %opts through
    # start_update, so the kwarg IS accepted here; per finding A17 / spec R69
    # an explicit caller value is honored (the default goes BEFORE %opts).
    # The pre-R69 code appended wait_for_stage => 'completed' AFTER %opts,
    # silently clobbering the caller's value.
    async method execute_update ($name, $args = [], %opts) {
        my $update_handle = await $self->start_update(
            $name, $args, wait_for_stage => 'completed', %opts);
        return await $update_handle->result;
    }

    # start_update($name, \@args, wait_for_stage => 'accepted'|'completed', %opts)
    # — async (spec section 19.1/19.2). Builds the UpdateWorkflowExecutionRequest
    # and calls UpdateWorkflowExecution in a retry loop until the response stage
    # is at least ACCEPTED (durability), then returns a
    # Temporalio::Client::WorkflowUpdateHandle seeded with the ref and any
    # returned outcome. 'admitted' is rejected with Argument before any RPC.
    # %opts: update_id (default a fresh UUID), wait_for_stage.
    async method start_update ($name, $args = [], %opts) {
        # Also guards execute_update, which funnels its caller options here.
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->start_update', \%opts,
            { headers => 1, wait_for_stage => 1, update_id => 1 });
        Temporalio::Exception::Argument->throw(
            message => 'start_update requires an update name (string)')
            unless defined $name && !ref $name && length $name;
        my $headers = delete $opts{headers} // {};
        my $input =
            Temporalio::Client::Interceptor::Input::StartWorkflowUpdate->new(
                update  => $name,
                args    => [ @$args ],
                headers => { %$headers },
                id      => $workflow_id,
                run_id  => $run_id,
                opts    => { %opts },
                _root   => async sub ($in) { await $self->_root_start_update($in) },
            );
        return await $client->_outbound->start_workflow_update($input);
    }

    async method _root_start_update ($input) {
        my $name = $input->get('update');
        my $args = $input->args;
        my %opts = %{ $input->get('opts') // {} };

        my $stage_name = delete $opts{wait_for_stage} // 'accepted';
        if ($stage_name eq 'admitted') {
            Temporalio::Exception::Argument->throw(
                message => "wait_for_stage => 'admitted' is not supported; use "
                         . "'accepted' or 'completed'");
        }
        my $wait_stage = $WAIT_STAGE{$stage_name}
            // Temporalio::Exception::Argument->throw(
                message => "unknown wait_for_stage '$stage_name' (expected "
                         . "'accepted' or 'completed')");

        my $update_id = delete $opts{update_id} // Temporalio::Client::_new_uuid();

        my $WaitPolicy = _resolve('temporal.api.update.v1.WaitPolicy');
        my $Meta       = _resolve('temporal.api.update.v1.Meta');
        my $Input      = _resolve('temporal.api.update.v1.Input');
        my $Request    = _resolve('temporal.api.update.v1.Request');

        my %input_fields = (name => $name);
        if (@$args) {
            $input_fields{args} = await $self->_encode_payloads($args);
        }

        my $request = _resolve(
            'temporal.api.workflowservice.v1.UpdateWorkflowExecutionRequest')
            ->new({
                namespace              => $client->namespace,
                workflow_execution     => $self->_execution_message,
                first_execution_run_id => $first_execution_run_id // '',
                wait_policy => $WaitPolicy->new({ lifecycle_stage => $wait_stage }),
                request     => $Request->new({
                    meta  => $Meta->new({
                        update_id => $update_id,
                        identity  => $client->identity,
                    }),
                    input => $Input->new(\%input_fields),
                }),
            });

        # Retry until the update is AT LEAST accepted (spec section 19.2): the
        # server may return early with UNSPECIFIED (0) before the worker has
        # accepted; re-issue the same request (idempotent on update_id) until the
        # reported stage is >= ACCEPTED.
        my $response;
        while (1) {
            $response =
                await $client->_rpc_call('UpdateWorkflowExecution', $request);
            my $stage = $response->stage // 0;
            last if $stage >= $WAIT_STAGE{accepted};
        }

        return $self->_update_handle($update_id,
            known_outcome => $response->outcome);
    }

    # get_update_handle($update_id, run_id => ..., result_type => ...) — build
    # a WorkflowUpdateHandle for a known update WITHOUT issuing any RPC (spec
    # R92 / parity audit client finding 2; sdk-python _workflow.py:978-1006,
    # with get_update_handle_for at :1008 as the typed sugar over the same
    # constructor). run_id defaults to this handle's own run id (Python :1001
    # "workflow_run_id or self._run_id"); result_type is the optional decode
    # hint the handle threads to payload decoding.
    method get_update_handle ($update_id, %opts) {
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->get_update_handle', \%opts,
            { run_id => 1, result_type => 1 });
        Temporalio::Exception::Argument->throw(
            message => 'get_update_handle requires an update id (string)')
            unless defined $update_id && !ref $update_id && length $update_id;
        return $self->_update_handle($update_id,
            run_id      => $opts{run_id},
            result_type => $opts{result_type},
        );
    }

    # The ONE construction point for update handles (spec R92 / parity audit
    # client finding 2): the owning client and workflow id always come from
    # this handle, and run_id defaults to the handle's own run when the caller
    # passes none (or undef). Both start_update's post-RPC handle and the
    # RPC-free get_update_handle route through here.
    method _update_handle ($update_id, %fields) {
        require Temporalio::Client::WorkflowUpdateHandle;
        return Temporalio::Client::WorkflowUpdateHandle->new(
            client      => $client,
            workflow_id => $workflow_id,
            update_id   => $update_id,
            %fields,
            run_id      => $fields{run_id} // $run_id,
        );
    }

    # fetch_history_events(...) — returns an async iterator over the workflow's
    # history events (spec section 7.6 / sdk-python _workflow.py
    # fetch_history_events 417-456). Defaults to ALL_EVENT, no waiting.
    method fetch_history_events (%opts) {
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowHandle->fetch_history_events', \%opts,
            { page_size => 1, wait_new_event => 1, event_filter_type => 1,
              skip_archival => 1 });
        my $filter = $opts{event_filter_type};
        $filter = 1 unless defined $filter;    # ALL_EVENT
        return $self->_history_iterator(
            $run_id,
            page_size         => $opts{page_size},
            wait_new_event    => $opts{wait_new_event} ? 1 : 0,
            event_filter_type => $filter,
            skip_archival     => $opts{skip_archival} ? 1 : 0,
        );
    }

    # ----- private helpers -------------------------------------------------

    # An async page iterator over GetWorkflowExecutionHistory for one run id.
    method _history_iterator ($the_run_id, %opts) {
        return Temporalio::Client::_HistoryEventIterator->new(
            client            => $client,
            workflow_id       => $workflow_id,
            run_id            => $the_run_id,
            page_size         => $opts{page_size},
            wait_new_event    => $opts{wait_new_event} ? 1 : 0,
            event_filter_type => $opts{event_filter_type} // 1,
            skip_archival     => $opts{skip_archival} ? 1 : 0,
        );
    }

    method _execution_message () {
        return _resolve('temporal.api.common.v1.WorkflowExecution')->new({
            workflow_id => $workflow_id,
            run_id      => $run_id // '',
        });
    }

    async method _encode_payloads ($values) {
        my @payloads = await $client->data_converter->to_payloads($values);
        return _resolve('temporal.api.common.v1.Payloads')
            ->new({ payloads => [@payloads] });
    }

    async method _decode_first_payload ($payloads_msg) {
        my @values = await $self->_decode_all_payloads($payloads_msg);
        return undef unless @values;
        return $values[0];
    }

    async method _decode_all_payloads ($payloads_msg) {
        return () unless defined $payloads_msg;
        my $payloads = $payloads_msg->payloads;
        return () unless defined $payloads && @$payloads;
        return await $client->data_converter->from_payloads($payloads);
    }

    sub _resolve ($name) { Temporalio::Core::Proto::resolve($name) }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::WorkflowHandle - handle to a Temporal workflow execution

=head1 SYNOPSIS

    my $handle = await $client->start_workflow(
        'MyWorkflow', \@args, id => 'wf-1', task_queue => 'demo');

    my $value  = await $handle->result;            # blocks until terminal
    my $desc   = await $handle->describe;
    await $handle->signal('greet', ['hi']);
    await $handle->cancel(reason => 'no longer needed');
    await $handle->terminate(reason => 'kill it', details => ['why']);

    # Or, without an RPC:
    my $handle = $client->get_workflow_handle('wf-1', run_id => $rid);

=head1 DESCRIPTION

A reference to a single workflow execution (spec section 7.6), returned by
C<< $client->start_workflow >>, C<< ->signal_with_start_workflow >>, and
C<< ->get_workflow_handle >>. It carries the C<workflow_id>, the C<run_id>
(first run id from start, or the run id supplied to
C<get_workflow_handle>), C<first_execution_run_id>, and C<result_run_id>,
plus a back-reference to the owning L<Temporalio::Client>.

Every method here rejects unknown option keys with a typed
L<Temporalio::Exception::Argument> before any RPC, via the shared
L<Temporalio::Common::Options> validator (spec R44): a typo such as
C<< result(follow_run => 0) >> raises instead of silently following
continue-as-new.

=head2 result

C<< await $handle->result >> long-polls C<GetWorkflowExecutionHistory> with
the C<CLOSE_EVENT> history-event filter and maps the single terminal event
to a value or exception, exactly per the Temporal spec (section 7.6,
verified against the reference SDK):

=over

=item * B<Completed> -> the decoded result payload value.

=item * B<Failed> -> L<Temporalio::Exception::WorkflowFailure> wrapping the
decoded failure as its C<cause>.

=item * B<TimedOut> -> C<WorkflowFailure> with cause
L<Temporalio::Exception::Timeout>.

=item * B<Canceled> -> C<WorkflowFailure> with cause
L<Temporalio::Exception::Cancelled>.

=item * B<Terminated> -> C<WorkflowFailure> with cause
L<Temporalio::Exception::Terminated> (the C<reason> preserved).

=item * B<ContinuedAsNew> -> with C<< follow_runs => 1 >> (the default) the
poll follows the new run; with C<< follow_runs => 0 >> it raises
L<Temporalio::Exception::WorkflowContinuedAsNew>.

=back

=head2 describe / cancel / terminate / signal / query / fetch_history_events

C<describe> returns the decoded C<DescribeWorkflowExecutionResponse>.
C<cancel> and C<terminate> issue their respective RPCs (threading
C<first_execution_run_id> through the run chain); C<terminate> encodes
C<details> through the data converter. C<signal> and C<query> send the named
signal/query with converter-encoded arguments; a server-rejected query
raises L<Temporalio::Exception::QueryRejected>. C<query> also accepts a
C<reject_condition> option naming a
C<temporal.api.enums.v1.QueryRejectCondition> value: C<'none'>,
C<'not_open'>, or C<'not_completed_cleanly'> (the same names as sdk-python's
C<QueryRejectCondition>); a raw proto enum number is passed through
unchanged, and any other value raises L<Temporalio::Exception::Argument>
before any RPC. When the per-call C<reject_condition> is omitted, the
client-level C<default_workflow_query_reject_condition> given to
C<< Temporalio::Client->connect >> applies instead (spec R93); a per-call
value always wins, and with neither set the request field stays unset.
C<fetch_history_events>
returns an async iterator over the workflow's history events.

=head2 reset

    my $new_run_id = await $handle->reset(
        workflow_task_finish_event_id => $event_id,   # required
        reason                        => '',
        reset_reapply_type            => 'signal',    # signal|none|all_eligible
        reset_reapply_exclude_types   => ['signal'],  # signal|update|nexus
        request_id                    => undef,        # default: fresh UUID
    );

Async (spec section 30.1). A thin, clearly-forked convenience helper (no
reference SDK ships one) that builds a C<ResetWorkflowExecutionRequest> and
funnels it through the client RPC path, returning the new run id. The current
run is terminated and a new run started.
C<workflow_task_finish_event_id> is required (the
C<WORKFLOW_TASK_COMPLETED>/C<TIMED_OUT>/C<FAILED>/C<STARTED> event id to reset
to); a missing id or a bad C<reset_reapply_type> /
C<reset_reapply_exclude_types> enum string raises
L<Temporalio::Exception::Argument> before any RPC. C<reset_reapply_type> (the
deprecated proto field) maps C<signal>/C<none>/C<all_eligible>;
C<reset_reapply_exclude_types> maps C<signal>/C<update>/C<nexus>. Server errors
map via spec section 7.5.

=head2 execute_update / start_update

C<< await $handle->execute_update($name, \@args, %opts) >> starts a workflow
update, waits for it to complete, and returns the decoded result (sugar over
C<start_update> followed by C<< ->result >>). C<wait_for_stage> defaults to
C<'completed'> as in the Python SDK; an explicit caller value is honored
rather than overridden. A failed outcome raises
L<Temporalio::Exception::WorkflowUpdateFailed>.

C<< await $handle->start_update($name, \@args, wait_for_stage =E<gt> 'accepted', %opts) >>
sends C<UpdateWorkflowExecution> (retrying until the update is at least
accepted) and returns a L<Temporalio::Client::WorkflowUpdateHandle>. The
C<wait_for_stage> option maps C<'accepted'> and C<'completed'> to the update
lifecycle stages; C<'admitted'> raises L<Temporalio::Exception::Argument> before
any RPC. C<%opts> also accepts an explicit C<update_id> (default: a fresh UUID).

=head2 get_update_handle

    my $uh = $handle->get_update_handle(
        $update_id,
        run_id      => $rid,      # default: this handle's run id
        result_type => $type,     # optional decode hint
    );
    my $r = await $uh->result;

Builds a L<Temporalio::Client::WorkflowUpdateHandle> for a known update id
without issuing any RPC (spec R92, sdk-python
C<WorkflowHandle.get_update_handle>). C<run_id> defaults to this handle's own
run id; C<result_type> is stored on the update handle and passed as the type
hint when the result payload is decoded. C<< $uh->result >> then polls
C<PollWorkflowExecutionUpdate> for the update's outcome. A missing update id
or an unknown option key raises L<Temporalio::Exception::Argument> before any
RPC.

=head1 METHODS

=head2 client

Accessor returning the C<client> value.

=head2 eagerly_started

Boolean accessor (spec section 23.1, eager start, detect-only): true when the
C<StartWorkflowExecutionResponse> carried an C<eager_workflow_task> (the server
returned the first workflow task for the shared core client to execute
in-process). Read-only; the language layer never routes the embedded task. False
when eager start was not requested or the server has it disabled.

=head2 first_execution_run_id

Accessor returning the C<first_execution_run_id> value.

=head2 result_run_id

Accessor returning the C<result_run_id> value.

=head2 run_id

Accessor returning the C<run_id> value.

=head2 workflow_id

Accessor returning the C<workflow_id> value.

=cut
