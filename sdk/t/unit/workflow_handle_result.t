# ABOUTME: Unit tests for the spec section 7.6 WorkflowHandle->result terminal-
# ABOUTME: event mapping (Completed/Failed/TimedOut/Canceled/Terminated/
# ABOUTME: ContinuedAsNew) plus describe/cancel/terminate/signal request shapes
# ABOUTME: and the Client list/count iterators — all over a mocked _rpc_call.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Scalar::Util ();
use Temporalio::Client ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Application ();

Temporalio::Core::Proto->load;

# ---------------------------------------------------------------------------
# A client whose _rpc_call is replaced by a scripted handler. Each call records
# the (rpc_name, request) it received and returns the next canned response (or
# dies with the next canned error). The handle/iterators never touch a live
# connection — they only go through _rpc_call.
# ---------------------------------------------------------------------------
sub resolve { Temporalio::Core::Proto::resolve($_[0]) }

# Per-object RPC mock registry, keyed by client refaddr.
our %MOCKS;

# Build a real Client but monkeypatch _rpc_call via a per-object handler the
# class consults. The class method _rpc_call delegates to the registered mock
# when one is set for that client instance.
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
    my $client = Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-test',
        identity       => 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
    return $client;
}

# Install a scripted mock returning the supplied closures in turn. Returns the
# arrayref the closures push their (rpc, request) records into.
sub script ($client, @responders) {
    my @calls;
    my $i = 0;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request, opts => \%opts };
        my $r = $responders[$i++]
            // die "unexpected extra RPC call: $rpc\n";
        # _rpc_call is async — the production caller awaits a Future, so the
        # mock must hand one back: Future->done on a value, Future->fail on a
        # responder that dies (e.g. a scripted RPC error).
        my $value = do { local $@; eval { $r->($rpc, $request, %opts) } };
        return Future->fail($@) if $@;
        return Future->done($value);
    };
    return \@calls;
}

# Run an async future to completion synchronously (these futures never suspend
# on IO — the mock resolves immediately).
sub run ($future) {
    $future->get;
}

sub caught ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

# Build a GetWorkflowExecutionHistoryResponse whose single close event carries
# the given attribute name + attribute message. close-event filter, so one
# page with one event and no next token.
sub history_close_response ($attr_field, $attr_msg) {
    my $Event = resolve('temporal.api.history.v1.HistoryEvent');
    my $Hist  = resolve('temporal.api.history.v1.History');
    my $Resp  = resolve(
        'temporal.api.workflowservice.v1.GetWorkflowExecutionHistoryResponse');
    my $event = $Event->new({ event_id => 1, $attr_field => $attr_msg });
    return $Resp->new({ history => $Hist->new({ events => [$event] }) });
}

sub payloads_of ($converter, @values) {
    my @p = $converter->to_payloads([@values])->get;
    return resolve('temporal.api.common.v1.Payloads')->new({ payloads => [@p] });
}

my $handle_args = sub ($client) {
    return Temporalio::Client::WorkflowHandle->new(
        client      => $client,
        workflow_id => 'wf-1',
        run_id      => 'run-1',
    );
};

# ---------------------------------------------------------------------------
# result(): WorkflowExecutionCompleted -> decoded result value
# ---------------------------------------------------------------------------
T2->subtest('result decodes a completed workflow result value' => sub {
    my $client = make_client;
    my $conv   = $client->data_converter;
    my $attrs  = resolve(
        'temporal.api.history.v1.WorkflowExecutionCompletedEventAttributes')
        ->new({ result => payloads_of($conv, 'hello-result') });
    my $calls = script($client, sub {
        return history_close_response(
            'workflow_execution_completed_event_attributes', $attrs);
    });
    my $handle = $handle_args->($client);
    my $value = run($handle->result);
    T2->is($value, 'hello-result', 'completed -> decoded payload value');
    T2->is($calls->[0]{rpc}, 'GetWorkflowExecutionHistory',
        'long-polls GetWorkflowExecutionHistory');
    my $req = $calls->[0]{request};
    T2->is($req->namespace, 'ns-test', 'request namespace');
    T2->is($req->execution->workflow_id, 'wf-1', 'request workflow id');
    T2->is($req->execution->run_id, 'run-1', 'request run id');
    T2->ok($req->wait_new_event, 'wait_new_event set');
    T2->ok($req->skip_archival, 'skip_archival set');
    T2->is($req->history_event_filter_type, 2,
        'history_event_filter_type CLOSE_EVENT (2)');
});

# ---------------------------------------------------------------------------
# result(): WorkflowExecutionFailed -> WorkflowFailure wrapping the cause
# ---------------------------------------------------------------------------
T2->subtest('result raises WorkflowFailure with the decoded failure cause' => sub {
    my $client = make_client;
    my $conv   = $client->data_converter;
    my $App    = Temporalio::Exception::Application->new(
        message => 'boom', type => 'BadThing');
    my $failure = $conv->to_failure($App)->get;
    my $attrs   = resolve(
        'temporal.api.history.v1.WorkflowExecutionFailedEventAttributes')
        ->new({ failure => $failure });
    script($client, sub {
        return history_close_response(
            'workflow_execution_failed_event_attributes', $attrs);
    });
    my $handle = $handle_args->($client);
    my $err = caught(sub { run($handle->result) });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowFailure'),
        'failed -> WorkflowFailure',
    ) or T2->diag('got: ' . ($err // 'none'));
    my $cause = $err->cause;
    T2->ok(
        Scalar::Util::blessed($cause)
            && $cause->isa('Temporalio::Exception::Application'),
        'cause is an Application failure',
    );
    T2->is($cause->type, 'BadThing', 'cause carries the application type');
});

# ---------------------------------------------------------------------------
# result(): TimedOut -> WorkflowFailure cause Timeout
# ---------------------------------------------------------------------------
T2->subtest('result raises WorkflowFailure cause Timeout on timeout' => sub {
    my $client = make_client;
    my $attrs  = resolve(
        'temporal.api.history.v1.WorkflowExecutionTimedOutEventAttributes')
        ->new({});
    script($client, sub {
        return history_close_response(
            'workflow_execution_timed_out_event_attributes', $attrs);
    });
    my $err = caught(sub { run($handle_args->($client)->result) });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowFailure'),
        'timed out -> WorkflowFailure',
    );
    T2->ok(
        Scalar::Util::blessed($err->cause)
            && $err->cause->isa('Temporalio::Exception::Timeout'),
        'cause is a Timeout',
    );
});

# ---------------------------------------------------------------------------
# result(): Canceled -> WorkflowFailure cause Cancelled
# ---------------------------------------------------------------------------
T2->subtest('result raises WorkflowFailure cause Cancelled on cancel' => sub {
    my $client = make_client;
    my $attrs  = resolve(
        'temporal.api.history.v1.WorkflowExecutionCanceledEventAttributes')
        ->new({});
    script($client, sub {
        return history_close_response(
            'workflow_execution_canceled_event_attributes', $attrs);
    });
    my $err = caught(sub { run($handle_args->($client)->result) });
    T2->ok(
        Scalar::Util::blessed($err->cause)
            && $err->cause->isa('Temporalio::Exception::Cancelled'),
        'cause is Cancelled',
    );
});

# ---------------------------------------------------------------------------
# result(): Terminated -> WorkflowFailure cause Terminated, reason preserved
# ---------------------------------------------------------------------------
T2->subtest('result raises WorkflowFailure cause Terminated with reason' => sub {
    my $client = make_client;
    my $attrs  = resolve(
        'temporal.api.history.v1.WorkflowExecutionTerminatedEventAttributes')
        ->new({ reason => 'because' });
    script($client, sub {
        return history_close_response(
            'workflow_execution_terminated_event_attributes', $attrs);
    });
    my $err = caught(sub { run($handle_args->($client)->result) });
    my $cause = $err->cause;
    T2->ok(
        Scalar::Util::blessed($cause)
            && $cause->isa('Temporalio::Exception::Terminated'),
        'cause is Terminated',
    );
    T2->is($cause->reason, 'because', 'terminated reason preserved');
});

# ---------------------------------------------------------------------------
# result(): ContinuedAsNew -> follow_runs follows; else WorkflowContinuedAsNew
# ---------------------------------------------------------------------------
T2->subtest('result follows continue-as-new when follow_runs (default)' => sub {
    my $client = make_client;
    my $conv   = $client->data_converter;
    my $can = resolve(
        'temporal.api.history.v1.WorkflowExecutionContinuedAsNewEventAttributes')
        ->new({ new_execution_run_id => 'run-2' });
    my $done = resolve(
        'temporal.api.history.v1.WorkflowExecutionCompletedEventAttributes')
        ->new({ result => payloads_of($conv, 'final') });
    my $calls = script(
        $client,
        sub {
            return history_close_response(
                'workflow_execution_continued_as_new_event_attributes', $can);
        },
        sub {
            return history_close_response(
                'workflow_execution_completed_event_attributes', $done);
        },
    );
    my $value = run($handle_args->($client)->result);
    T2->is($value, 'final', 'followed to the new run and returned its result');
    T2->is($calls->[1]{request}->execution->run_id, 'run-2',
        'second poll targets the new run id');
});

T2->subtest('result(follow_runs => 0) raises WorkflowContinuedAsNew' => sub {
    my $client = make_client;
    my $can = resolve(
        'temporal.api.history.v1.WorkflowExecutionContinuedAsNewEventAttributes')
        ->new({ new_execution_run_id => 'run-2' });
    script($client, sub {
        return history_close_response(
            'workflow_execution_continued_as_new_event_attributes', $can);
    });
    my $err = caught(sub {
        run($handle_args->($client)->result(follow_runs => 0));
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowContinuedAsNew'),
        'not following -> WorkflowContinuedAsNew',
    );
    T2->is($err->new_run_id, 'run-2', 'carries the new run id');
});

# ---------------------------------------------------------------------------
# describe(): issues DescribeWorkflowExecution and returns the response record
# ---------------------------------------------------------------------------
T2->subtest('describe issues DescribeWorkflowExecution with the execution' => sub {
    my $client = make_client;
    my $Info = resolve('temporal.api.workflow.v1.WorkflowExecutionInfo');
    my $WfExec = resolve('temporal.api.common.v1.WorkflowExecution');
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.DescribeWorkflowExecutionResponse');
    my $resp = $Resp->new({ workflow_execution_info => $Info->new({
        execution => $WfExec->new({ workflow_id => 'wf-1', run_id => 'run-1' }),
        status    => 1,
    }) });
    my $calls = script($client, sub { return $resp });
    my $desc = run($handle_args->($client)->describe);
    T2->is($calls->[0]{rpc}, 'DescribeWorkflowExecution', 'describe rpc');
    my $req = $calls->[0]{request};
    T2->is($req->namespace, 'ns-test', 'describe namespace');
    T2->is($req->execution->workflow_id, 'wf-1', 'describe workflow id');
    T2->is($req->execution->run_id, 'run-1', 'describe run id');
    T2->is($desc->workflow_execution_info->execution->workflow_id, 'wf-1',
        'returns the populated info record');
});

# ---------------------------------------------------------------------------
# cancel(): issues RequestCancelWorkflowExecution
# ---------------------------------------------------------------------------
T2->subtest('cancel issues RequestCancelWorkflowExecution' => sub {
    my $client = make_client;
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.RequestCancelWorkflowExecutionResponse');
    my $calls = script($client, sub { return $Resp->new({}) });
    run($handle_args->($client)->cancel);
    T2->is($calls->[0]{rpc}, 'RequestCancelWorkflowExecution', 'cancel rpc');
    my $req = $calls->[0]{request};
    T2->is($req->namespace, 'ns-test', 'cancel namespace');
    T2->is($req->workflow_execution->workflow_id, 'wf-1', 'cancel workflow id');
    T2->is($req->identity, 'id-test@host', 'cancel identity');
    T2->like($req->request_id, qr/\S/, 'cancel request id set');
});

# ---------------------------------------------------------------------------
# terminate(): issues TerminateWorkflowExecution with reason + details
# ---------------------------------------------------------------------------
T2->subtest('terminate issues TerminateWorkflowExecution with reason/details' => sub {
    my $client = make_client;
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.TerminateWorkflowExecutionResponse');
    my $calls = script($client, sub { return $Resp->new({}) });
    run($handle_args->($client)->terminate(
        reason => 'stop it', details => ['d1']));
    T2->is($calls->[0]{rpc}, 'TerminateWorkflowExecution', 'terminate rpc');
    my $req = $calls->[0]{request};
    T2->is($req->reason, 'stop it', 'terminate reason');
    T2->is($req->workflow_execution->workflow_id, 'wf-1', 'terminate workflow id');
    T2->ok(defined $req->details && @{ $req->details->payloads } == 1,
        'terminate details encoded to one payload');
});

# ---------------------------------------------------------------------------
# signal(): issues SignalWorkflowExecution with the name + encoded args
# ---------------------------------------------------------------------------
T2->subtest('signal issues SignalWorkflowExecution' => sub {
    my $client = make_client;
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.SignalWorkflowExecutionResponse');
    my $calls = script($client, sub { return $Resp->new({}) });
    run($handle_args->($client)->signal('greet', ['hi']));
    T2->is($calls->[0]{rpc}, 'SignalWorkflowExecution', 'signal rpc');
    my $req = $calls->[0]{request};
    T2->is($req->signal_name, 'greet', 'signal name');
    T2->ok(defined $req->input && @{ $req->input->payloads } == 1,
        'signal arg encoded to one payload');
});

# ---------------------------------------------------------------------------
# Client->count_workflows: { count => N, groups => [...] }
# ---------------------------------------------------------------------------
T2->subtest('count_workflows returns count + groups' => sub {
    my $client = make_client;
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.CountWorkflowExecutionsResponse');
    my $calls = script($client, sub { return $Resp->new({ count => 7 }) });
    my $result = run($client->count_workflows('WorkflowType="X"'));
    T2->is($calls->[0]{rpc}, 'CountWorkflowExecutions', 'count rpc');
    T2->is($calls->[0]{request}->query, 'WorkflowType="X"', 'count query');
    T2->is($result->{count}, 7, 'count value');
    T2->is(ref $result->{groups}, 'ARRAY', 'groups is an arrayref');
});

# ---------------------------------------------------------------------------
# Client->list_workflows: async iterator paging through next_page_token
# ---------------------------------------------------------------------------
T2->subtest('list_workflows iterates across pages via next_page_token' => sub {
    my $client = make_client;
    my $Info = resolve('temporal.api.workflow.v1.WorkflowExecutionInfo');
    my $WfExec = resolve('temporal.api.common.v1.WorkflowExecution');
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.ListWorkflowExecutionsResponse');
    my $mk = sub ($id, $token) {
        return $Resp->new({
            executions => [ $Info->new({
                execution => $WfExec->new({ workflow_id => $id }) }) ],
            ($token ? (next_page_token => $token) : ()),
        });
    };
    my $calls = script(
        $client,
        sub { return $mk->('wf-a', 'tok1') },
        sub { return $mk->('wf-b', undef) },
    );
    my $iter = $client->list_workflows('WorkflowType="X"');
    my @ids;
    while (defined(my $exec = run($iter->next))) {
        push @ids, $exec->execution->workflow_id;
    }
    T2->is(\@ids, ['wf-a', 'wf-b'], 'iterated both pages in order');
    T2->is($calls->[0]{rpc}, 'ListWorkflowExecutions', 'list rpc');
    T2->is($calls->[1]{request}->next_page_token, 'tok1',
        'second page carries the prior next_page_token');
});

T2->done_testing;
