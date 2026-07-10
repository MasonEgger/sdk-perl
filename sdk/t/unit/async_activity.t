# ABOUTME: Unit tests for spec section 22 async activity completion — the
# ABOUTME: client->async_activity_handle keyword union (token-xor-id) arg guards
# ABOUTME: (T-asyncact-8), the eight Respond/Record request builders by explicit
# ABOUTME: field, the heartbeat-response cancellation raise, and the worker-side
# ABOUTME: complete_async verb + WillCompleteAsync completion shaping.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Activity ();
use Temporalio::Client ();
use Temporalio::Client::AsyncActivityHandle ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Activity::AsyncActivityCancelled ();
use Temporalio::Exception::Activity::CompleteAsync ();
use Temporalio::Exception::Application ();
use Temporalio::Worker::ActivityCompletion ();

Temporalio::Core::Proto->load;

# A client with no live connection: the handle's request builders only read
# namespace/identity/data_converter, never the connection pointer.
sub make_client (%override) {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => $override{namespace} // 'ns-async',
        identity       => $override{identity}  // 'id-async@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# ---------------------------------------------------------------------------
# T-asyncact-8: the three invalid keyword combos raise Argument pre-RPC
# ---------------------------------------------------------------------------
T2->subtest('async_activity_handle arg validation' => sub {
    my $client = make_client;

    my $both = T2->dies(sub {
        $client->async_activity_handle(
            task_token => 'tok', workflow_id => 'wf', activity_id => 'a');
    });
    T2->ok($both && $both->isa('Temporalio::Exception::Argument'),
        'task_token + id triple -> Argument');

    my $wf_no_act = T2->dies(sub {
        $client->async_activity_handle(workflow_id => 'wf');
    });
    T2->ok($wf_no_act && $wf_no_act->isa('Temporalio::Exception::Argument'),
        'workflow_id without activity_id -> Argument');

    my $neither = T2->dies(sub { $client->async_activity_handle() });
    T2->ok($neither && $neither->isa('Temporalio::Exception::Argument'),
        'neither token nor id -> Argument');

    # run_id without workflow_id is also incomplete (no workflow_id) -> Argument.
    my $run_only = T2->dies(sub {
        $client->async_activity_handle(run_id => 'r', activity_id => 'a');
    });
    T2->ok($run_only && $run_only->isa('Temporalio::Exception::Argument'),
        'run_id+activity_id without workflow_id -> Argument');
});

# ---------------------------------------------------------------------------
# Valid construction: token handle and id-reference handle, no RPC
# ---------------------------------------------------------------------------
T2->subtest('valid handles construct without an RPC' => sub {
    my $client = make_client;

    my $by_token = $client->async_activity_handle(task_token => 'rawtoken');
    T2->isa_ok($by_token, 'Temporalio::Client::AsyncActivityHandle');
    T2->is($by_token->task_token, 'rawtoken', 'task_token stored');
    T2->ok(!defined $by_token->id_reference, 'no id_reference on a token handle');

    my $by_id = $client->async_activity_handle(
        workflow_id => 'wf-1', run_id => 'run-1', activity_id => 'act-1');
    T2->isa_ok($by_id, 'Temporalio::Client::AsyncActivityHandle');
    T2->ok(!defined $by_id->task_token, 'no task_token on an id handle');
    T2->is($by_id->id_reference->{workflow_id}, 'wf-1', 'id_reference workflow_id');
    T2->is($by_id->id_reference->{run_id}, 'run-1', 'id_reference run_id');
    T2->is($by_id->id_reference->{activity_id}, 'act-1', 'id_reference activity_id');
});

# ---------------------------------------------------------------------------
# T-asyncact-1/2/9: complete by token and by id
# ---------------------------------------------------------------------------
T2->subtest('complete builds the right request (token + ById)' => sub {
    my $client = make_client;

    my $h = $client->async_activity_handle(task_token => 'tok-c');
    my $req = $h->_build_complete_request('the-result')->get;
    T2->isa_ok($req,
        'Temporalio::Proto::Api::Workflowservice::V1::RespondActivityTaskCompletedRequest');
    T2->is($req->task_token, 'tok-c', 'task_token set');
    T2->is($req->namespace, 'ns-async', 'namespace from client');
    T2->is($req->identity, 'id-async@host', 'identity from client');
    T2->is($req->result->payloads->[0]->data, '"the-result"', 'result payload (json/plain)');

    # T-asyncact-9: no result -> empty result field
    my $void = $h->_build_complete_request()->get;
    T2->ok(!defined $void->result, 'no result -> result field absent');

    my $hid = $client->async_activity_handle(
        workflow_id => 'wf', run_id => 'run', activity_id => 'act');
    my $reqid = $hid->_build_complete_request('r')->get;
    T2->isa_ok($reqid,
        'Temporalio::Proto::Api::Workflowservice::V1::RespondActivityTaskCompletedByIdRequest');
    T2->is($reqid->workflow_id, 'wf', 'ById workflow_id');
    T2->is($reqid->run_id, 'run', 'ById run_id');
    T2->is($reqid->activity_id, 'act', 'ById activity_id');
    T2->is($reqid->namespace, 'ns-async', 'ById namespace');
    T2->is($reqid->identity, 'id-async@host', 'ById identity');
    T2->is($reqid->result->payloads->[0]->data, '"r"', 'ById result payload (json/plain)');
});

# ---------------------------------------------------------------------------
# T-asyncact-3: fail carries last_heartbeat_details
# ---------------------------------------------------------------------------
T2->subtest('fail builds request with failure + last_heartbeat_details' => sub {
    my $client = make_client;
    my $err = Temporalio::Exception::Application->new(message => 'boom');

    my $h = $client->async_activity_handle(task_token => 'tok-f');
    my $req = $h->_build_fail_request($err,
        last_heartbeat_details => [ 'hb1' ])->get;
    T2->isa_ok($req,
        'Temporalio::Proto::Api::Workflowservice::V1::RespondActivityTaskFailedRequest');
    T2->is($req->task_token, 'tok-f', 'task_token set');
    T2->is($req->namespace, 'ns-async', 'namespace');
    T2->ok(defined $req->failure, 'failure proto present');
    T2->is($req->last_heartbeat_details->payloads->[0]->data, '"hb1"',
        'last_heartbeat_details payload (json/plain)');

    # default: no last_heartbeat_details
    my $req2 = $h->_build_fail_request($err)->get;
    T2->ok(!defined $req2->last_heartbeat_details,
        'no last_heartbeat_details -> field absent');

    my $hid = $client->async_activity_handle(
        workflow_id => 'wf', activity_id => 'act');
    my $reqid = $hid->_build_fail_request($err,
        last_heartbeat_details => [ 'h' ])->get;
    T2->isa_ok($reqid,
        'Temporalio::Proto::Api::Workflowservice::V1::RespondActivityTaskFailedByIdRequest');
    T2->is($reqid->workflow_id, 'wf', 'ById workflow_id');
    T2->is($reqid->activity_id, 'act', 'ById activity_id');
    T2->is($reqid->last_heartbeat_details->payloads->[0]->data, '"h"',
        'ById last_heartbeat_details (json/plain)');
});

# ---------------------------------------------------------------------------
# T-asyncact-4: report_cancellation
# ---------------------------------------------------------------------------
T2->subtest('report_cancellation builds Canceled request' => sub {
    my $client = make_client;

    my $h = $client->async_activity_handle(task_token => 'tok-x');
    my $req = $h->_build_report_cancellation_request('d1', 'd2')->get;
    T2->isa_ok($req,
        'Temporalio::Proto::Api::Workflowservice::V1::RespondActivityTaskCanceledRequest');
    T2->is($req->task_token, 'tok-x', 'task_token');
    T2->is($req->namespace, 'ns-async', 'namespace');
    T2->is($req->details->payloads->[0]->data, '"d1"', 'details payload 0 (json/plain)');
    T2->is($req->details->payloads->[1]->data, '"d2"', 'details payload 1 (json/plain)');

    my $empty = $h->_build_report_cancellation_request()->get;
    T2->ok(!defined $empty->details, 'no details -> details field absent');

    my $hid = $client->async_activity_handle(
        workflow_id => 'wf', activity_id => 'act');
    my $reqid = $hid->_build_report_cancellation_request('d')->get;
    T2->isa_ok($reqid,
        'Temporalio::Proto::Api::Workflowservice::V1::RespondActivityTaskCanceledByIdRequest');
    T2->is($reqid->activity_id, 'act', 'ById activity_id');
});

# ---------------------------------------------------------------------------
# T-asyncact-5: heartbeat request building
# ---------------------------------------------------------------------------
T2->subtest('heartbeat builds Record request with details' => sub {
    my $client = make_client;

    my $h = $client->async_activity_handle(task_token => 'tok-h');
    my $req = $h->_build_heartbeat_request('beat')->get;
    T2->isa_ok($req,
        'Temporalio::Proto::Api::Workflowservice::V1::RecordActivityTaskHeartbeatRequest');
    T2->is($req->task_token, 'tok-h', 'task_token');
    T2->is($req->namespace, 'ns-async', 'namespace');
    T2->is($req->identity, 'id-async@host', 'identity');
    T2->is($req->details->payloads->[0]->data, '"beat"', 'details payload (json/plain)');

    my $hid = $client->async_activity_handle(
        workflow_id => 'wf', run_id => 'run', activity_id => 'act');
    my $reqid = $hid->_build_heartbeat_request('beat')->get;
    T2->isa_ok($reqid,
        'Temporalio::Proto::Api::Workflowservice::V1::RecordActivityTaskHeartbeatByIdRequest');
    T2->is($reqid->workflow_id, 'wf', 'ById workflow_id');
    T2->is($reqid->run_id, 'run', 'ById run_id');
    T2->is($reqid->activity_id, 'act', 'ById activity_id');
});

# ---------------------------------------------------------------------------
# T-asyncact-6: a cancel/pause/reset heartbeat response raises
# AsyncActivityCancelled with the right flags.
# ---------------------------------------------------------------------------
T2->subtest('heartbeat response flags raise AsyncActivityCancelled' => sub {
    my $Resp = Temporalio::Core::Proto::resolve(
        'temporal.api.workflowservice.v1.RecordActivityTaskHeartbeatResponse');

    my $no_cancel = $Resp->new({});
    T2->ok(
        !Temporalio::Client::AsyncActivityHandle::_cancellation_from_response($no_cancel),
        'no flags -> no cancellation');

    for my $field (qw(cancel_requested activity_paused activity_reset)) {
        my $resp = $Resp->new({ $field => 1 });
        my $exc = Temporalio::Client::AsyncActivityHandle::_cancellation_from_response($resp);
        T2->ok($exc, "$field set -> cancellation exception built");
        T2->ok($exc->isa('Temporalio::Exception::Activity::AsyncActivityCancelled'),
            "$field -> AsyncActivityCancelled");
        T2->ok($exc->$field, "$field accessor true");
    }
});

# ---------------------------------------------------------------------------
# Worker side: complete_async verb throws CompleteAsync; the completion helper
# shapes a WillCompleteAsync ActivityExecutionResult.
# ---------------------------------------------------------------------------
T2->subtest('complete_async verb throws CompleteAsync' => sub {
    my $err = T2->dies(sub { Temporalio::Activity::complete_async() });
    T2->ok($err && $err->isa('Temporalio::Exception::Activity::CompleteAsync'),
        'complete_async throws CompleteAsync');
});

T2->subtest('will_complete_async completion shapes the proto' => sub {
    my $bytes = Temporalio::Worker::ActivityCompletion::will_complete_async('tok-w');
    my $Completion = Temporalio::Core::Proto::resolve('coresdk.ActivityTaskCompletion');
    my $back = $Completion->decode($bytes);
    T2->is($back->task_token, 'tok-w', 'task_token round-trips');
    T2->is($back->result->which_status, 'will_complete_async',
        'result is the will_complete_async variant');
});

T2->done_testing;
