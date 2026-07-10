# ABOUTME: R44 (finding A10) strictness sweep: every public client-surface
# ABOUTME: method rejects an unknown option key with a typed
# ABOUTME: Temporalio::Exception::Argument naming the key, and the real/known
# ABOUTME: option keys are still accepted — one rule across Client + handles.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Scalar::Util ();

use Temporalio::Client ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Client::WorkflowUpdateHandle ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Application ();
use Temporalio::Exception::Argument ();
use Temporalio::Schedule ();

Temporalio::Core::Proto->load;

sub resolve { Temporalio::Core::Proto::resolve($_[0]) }

# ---------------------------------------------------------------------------
# The same per-object _rpc_call mock registry as workflow_handle_result.t: a
# real Client whose RPC layer is a scripted handler, so no live connection is
# ever touched. Option validation MUST fire before any RPC, so the strict
# default mock fails loudly when a call reaches it.
# ---------------------------------------------------------------------------
our %MOCKS;
{
    no warnings 'redefine';
    my $orig = \&Temporalio::Client::_rpc_call;
    *Temporalio::Client::_rpc_call = sub {
        my ($self, $rpc, $request, %opts) = @_;
        if (my $mock = $MOCKS{ Scalar::Util::refaddr($self) }) {
            return $mock->($rpc, $request, %opts);
        }
        return $orig->($self, $rpc, $request, %opts);
    };
}

sub make_client {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-test',
        identity       => 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# A client whose RPC layer rejects every call: the typo sweep must never get
# that far (validation precedes any RPC).
sub strict_client {
    my $client = make_client;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub ($rpc, @) {
        return Future->fail(
            "unexpected RPC '$rpc': unknown-option validation did not fire\n");
    };
    return $client;
}

# Install a scripted mock returning the supplied closures in turn; records
# every (rpc, request) it saw.
sub script ($client, @responders) {
    my @calls;
    my $i = 0;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request, opts => \%opts };
        my $r = $responders[$i++]
            // die "unexpected extra RPC call: $rpc\n";
        my $value = do { local $@; eval { $r->($rpc, $request, %opts) } };
        return Future->fail($@) if $@;
        return Future->done($value);
    };
    return \@calls;
}

# Run a call that may hand back a Future (async methods) or a plain value.
sub run_call ($thing) {
    return $thing->get
        if Scalar::Util::blessed($thing) && $thing->isa('Future');
    return $thing;
}

sub caught ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub a_schedule {
    return Temporalio::Schedule::Schedule->new(
        action => Temporalio::Schedule::Action::StartWorkflow->new(
            workflow => 'MyWorkflow', args => ['arg1'],
            id => 'sched-wf', task_queue => 'tq'),
        spec   => Temporalio::Schedule::Spec->new(
            intervals => [ Temporalio::Schedule::Interval->new(every => 3600) ]),
    );
}

sub an_error {
    return Temporalio::Exception::Application->new(
        message => 'boom', type => 'BadThing');
}

sub payloads_of ($converter, @values) {
    my @p = $converter->to_payloads([@values])->get;
    return resolve('temporal.api.common.v1.Payloads')->new({ payloads => [@p] });
}

# ---------------------------------------------------------------------------
# Typo sweep (finding A10): a bogus option key raises the typed argument
# error, everywhere on the client surface. result() uses the exact defect
# typo from the audit (follow_run for follow_runs).
# ---------------------------------------------------------------------------
my @typo_cases = (
    [ 'Client->connect' => sub ($c, $h) {
        Temporalio::Client->connect('localhost:7233', bogus => 1) } ],
    [ 'Client->get_workflow_handle' => sub ($c, $h) {
        $c->get_workflow_handle('wf', bogus => 1) } ],
    [ 'Client->start_workflow' => sub ($c, $h) {
        $c->start_workflow('WF', [], id => 'i', task_queue => 'tq', bogus => 1) } ],
    [ 'Client->execute_workflow' => sub ($c, $h) {
        $c->execute_workflow('WF', [], id => 'i', task_queue => 'tq', bogus => 1) } ],
    [ 'Client->signal_with_start_workflow' => sub ($c, $h) {
        $c->signal_with_start_workflow('WF', [],
            id => 'i', task_queue => 'tq', signal => 'sig', bogus => 1) } ],
    [ 'Client->list_workflows' => sub ($c, $h) {
        $c->list_workflows(undef, bogus => 1) } ],
    [ 'Client->count_workflows' => sub ($c, $h) {
        $c->count_workflows(undef, bogus => 1) } ],
    [ 'Client->create_schedule' => sub ($c, $h) {
        $c->create_schedule('sid', a_schedule(), bogus => 1) } ],
    [ 'Client->list_schedules' => sub ($c, $h) {
        $c->list_schedules(undef, bogus => 1) } ],
    [ 'Client->async_activity_handle' => sub ($c, $h) {
        $c->async_activity_handle(task_token => 'tt', bogus => 1) } ],
    [ 'Client->reset_workflow' => sub ($c, $h) {
        $c->reset_workflow('wf', 'r',
            workflow_task_finish_event_id => 3, bogus => 1) } ],
    [ 'WorkflowHandle->result' => sub ($c, $h) {
        $h->result(follow_run => 0) } ],
    [ 'WorkflowHandle->describe' => sub ($c, $h) {
        $h->describe(bogus => 1) } ],
    [ 'WorkflowHandle->cancel' => sub ($c, $h) {
        $h->cancel(bogus => 1) } ],
    [ 'WorkflowHandle->terminate' => sub ($c, $h) {
        $h->terminate(bogus => 1) } ],
    [ 'WorkflowHandle->signal' => sub ($c, $h) {
        $h->signal('sig', [], bogus => 1) } ],
    [ 'WorkflowHandle->query' => sub ($c, $h) {
        $h->query('q', [], bogus => 1) } ],
    [ 'WorkflowHandle->start_update' => sub ($c, $h) {
        $h->start_update('u', [], bogus => 1) } ],
    [ 'WorkflowHandle->execute_update' => sub ($c, $h) {
        $h->execute_update('u', [], bogus => 1) } ],
    [ 'WorkflowHandle->reset' => sub ($c, $h) {
        $h->reset(workflow_task_finish_event_id => 3, bogus => 1) } ],
    [ 'WorkflowHandle->fetch_history_events' => sub ($c, $h) {
        $h->fetch_history_events(bogus => 1) } ],
    [ 'AsyncActivityHandle->fail' => sub ($c, $h) {
        $c->async_activity_handle(task_token => 'tt')
          ->fail(an_error(), bogus => 1) } ],
    [ 'WorkflowUpdateHandle->result' => sub ($c, $h) {
        Temporalio::Client::WorkflowUpdateHandle->new(
            client => $c, workflow_id => 'wf', run_id => 'r',
            update_id => 'u')->result(bogus => 1) } ],
    [ 'ScheduleHandle->trigger' => sub ($c, $h) {
        $c->get_schedule_handle('sid')->trigger(bogus => 1) } ],
    [ 'ScheduleHandle->pause' => sub ($c, $h) {
        $c->get_schedule_handle('sid')->pause(bogus => 1) } ],
    [ 'ScheduleHandle->unpause' => sub ($c, $h) {
        $c->get_schedule_handle('sid')->unpause(bogus => 1) } ],
);

T2->subtest('unknown option key raises the typed argument error everywhere' => sub {
    for my $case (@typo_cases) {
        my ($name, $call) = @$case;
        my $client = strict_client;
        my $handle = $client->get_workflow_handle('wf-1', run_id => 'run-1');
        my $err = caught(sub { run_call($call->($client, $handle)) });
        T2->ok(
            Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::Argument'),
            "$name: typo raises Temporalio::Exception::Argument",
        ) or T2->diag("$name got: " . ($err // 'no error'));
        my $msg = Scalar::Util::blessed($err) ? $err->message : ($err // '');
        T2->like($msg, qr/unknown option/,
            "$name: the error names an unknown option");
    }
});

# ---------------------------------------------------------------------------
# Known keys are still accepted: each strictness site with real options keeps
# working when every documented key is passed.
# ---------------------------------------------------------------------------
T2->subtest('get_workflow_handle known keys accepted' => sub {
    my $client = strict_client;
    my $h = $client->get_workflow_handle('wf-1',
        run_id => 'r-1', first_execution_run_id => 'f-1');
    T2->is($h->run_id, 'r-1', 'run_id accepted');
    T2->is($h->first_execution_run_id, 'f-1', 'first_execution_run_id accepted');
});

T2->subtest('list iterators accept page_size' => sub {
    my $client = strict_client;
    my $wf_iter = $client->list_workflows(undef, page_size => 5);
    T2->ok($wf_iter && $wf_iter->can('next'), 'list_workflows iterator');
    my $sched_iter = $client->list_schedules(undef, page_size => 5);
    T2->ok($sched_iter && $sched_iter->can('next'), 'list_schedules iterator');
});

T2->subtest('start_workflow known keys accepted' => sub {
    my $client = make_client;
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.StartWorkflowExecutionResponse');
    script($client, sub { return $Resp->new({ run_id => 'r-new' }) });
    my $h = run_call($client->start_workflow('WF', [],
        id => 'i-1', task_queue => 'tq', memo => { k => 'v' },
        execution_timeout => 5));
    T2->is($h->run_id, 'r-new', 'started with known keys');
});

T2->subtest('result(follow_runs => 0) known key accepted' => sub {
    my $client = make_client;
    my $conv   = $client->data_converter;
    my $attrs  = resolve(
        'temporal.api.history.v1.WorkflowExecutionCompletedEventAttributes')
        ->new({ result => payloads_of($conv, 'val') });
    my $Event = resolve('temporal.api.history.v1.HistoryEvent');
    my $Hist  = resolve('temporal.api.history.v1.History');
    my $Resp  = resolve(
        'temporal.api.workflowservice.v1.GetWorkflowExecutionHistoryResponse');
    script($client, sub {
        return $Resp->new({ history => $Hist->new({ events => [
            $Event->new({ event_id => 1,
                workflow_execution_completed_event_attributes => $attrs }),
        ] }) });
    });
    my $h = $client->get_workflow_handle('wf-1', run_id => 'run-1');
    T2->is(run_call($h->result(follow_runs => 0)), 'val',
        'follow_runs accepted and result decoded');
});

T2->subtest('cancel/terminate known keys accepted' => sub {
    my $client = make_client;
    my $CancelResp = resolve(
        'temporal.api.workflowservice.v1.RequestCancelWorkflowExecutionResponse');
    my $TermResp = resolve(
        'temporal.api.workflowservice.v1.TerminateWorkflowExecutionResponse');
    my $calls = script($client,
        sub { return $CancelResp->new({}) },
        sub { return $TermResp->new({}) },
    );
    my $h = $client->get_workflow_handle('wf-1', run_id => 'run-1');
    run_call($h->cancel(reason => 'why'));
    run_call($h->terminate(reason => 'why', details => ['d']));
    T2->is($calls->[0]{rpc}, 'RequestCancelWorkflowExecution', 'cancel ran');
    T2->is($calls->[0]{request}->reason, 'why', 'cancel reason accepted');
    T2->is($calls->[1]{rpc}, 'TerminateWorkflowExecution', 'terminate ran');
});

T2->subtest('signal/query known keys accepted' => sub {
    my $client = make_client;
    my $conv   = $client->data_converter;
    my $SigResp = resolve(
        'temporal.api.workflowservice.v1.SignalWorkflowExecutionResponse');
    my $QueryResp = resolve(
        'temporal.api.workflowservice.v1.QueryWorkflowResponse');
    my $calls = script($client,
        sub { return $SigResp->new({}) },
        sub ($rpc, $request, %opts) {
            return $QueryResp->new({
                query_result => payloads_of($conv, 'answer') });
        },
    );
    my $h = $client->get_workflow_handle('wf-1', run_id => 'run-1');
    run_call($h->signal('sig', ['a'], headers => {}));
    T2->is($calls->[0]{rpc}, 'SignalWorkflowExecution', 'signal ran');
    my $answer = run_call($h->query('q', [],
        reject_condition => 1, headers => {}));
    T2->is($answer, 'answer', 'query with known keys decoded');
    T2->is($calls->[1]{request}->query_reject_condition, 1,
        'reject_condition accepted');
});

T2->subtest('start_update known keys accepted' => sub {
    my $client = make_client;
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.UpdateWorkflowExecutionResponse');
    script($client, sub { return $Resp->new({ stage => 3 }) });
    my $h = $client->get_workflow_handle('wf-1', run_id => 'run-1');
    my $update = run_call($h->start_update('u', [],
        wait_for_stage => 'completed', update_id => 'uid-1', headers => {}));
    T2->is($update->update_id, 'uid-1', 'update handle with known keys');
});

T2->subtest('reset known keys accepted' => sub {
    my $client = make_client;
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.ResetWorkflowExecutionResponse');
    script($client, sub { return $Resp->new({ run_id => 'r-reset' }) });
    my $h = $client->get_workflow_handle('wf-1', run_id => 'run-1');
    my $new_run = run_call($h->reset(
        workflow_task_finish_event_id => 3,
        reason                        => 'because',
        reset_reapply_type            => 'signal',
        reset_reapply_exclude_types   => ['signal'],
        request_id                    => 'rid-1',
    ));
    T2->is($new_run, 'r-reset', 'reset with every known key');
});

T2->subtest('fetch_history_events known keys accepted' => sub {
    my $client = strict_client;
    my $h = $client->get_workflow_handle('wf-1', run_id => 'run-1');
    my $iter = $h->fetch_history_events(
        page_size => 5, wait_new_event => 0,
        event_filter_type => 1, skip_archival => 1);
    T2->ok($iter && $iter->can('next'), 'iterator with known keys');
});

T2->subtest('async activity fail known key accepted' => sub {
    my $client = make_client;
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.RespondActivityTaskFailedResponse');
    my $calls = script($client, sub { return $Resp->new({}) });
    my $ah = $client->async_activity_handle(task_token => 'tt');
    run_call($ah->fail(an_error(), last_heartbeat_details => ['hb']));
    T2->is($calls->[0]{rpc}, 'RespondActivityTaskFailed',
        'fail with last_heartbeat_details ran');
    T2->ok(defined $calls->[0]{request}->last_heartbeat_details,
        'heartbeat details carried');
});

T2->done_testing;
