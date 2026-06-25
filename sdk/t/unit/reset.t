# ABOUTME: Unit tests for the spec section 30.1 workflow reset helper —
# ABOUTME: ResetWorkflowExecutionRequest round-trip, reapply enum mapping, and
# ABOUTME: the pre-RPC Argument guards (T-reset-1/2).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();
use Temporalio::Client ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();

Temporalio::Core::Proto->load;

# A client built without a live connection: the reset request builder never
# touches the connection pointer, only namespace/identity.
sub make_client (%override) {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => $override{namespace} // 'ns-test',
        identity       => $override{identity}  // 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

sub make_handle (%opts) {
    return Temporalio::Client::WorkflowHandle->new(
        client      => make_client(%opts),
        workflow_id => $opts{workflow_id} // 'wf-reset',
        run_id      => $opts{run_id},
    );
}

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub is_argument_exc ($err) {
    return Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Argument');
}

# ---------------------------------------------------------------------------
# T-reset-1: full kwargs -> ResetWorkflowExecutionRequest round-trip
# ---------------------------------------------------------------------------
T2->subtest('all kwargs land in the right request fields (T-reset-1)' => sub {
    my $handle = make_handle(run_id => 'run-abc');
    my $req = $handle->_build_reset_request(
        workflow_task_finish_event_id => 7,
        reason                        => 'because',
        reset_reapply_type            => 'all_eligible',
        reset_reapply_exclude_types   => [ 'signal', 'update' ],
        request_id                    => 'fixed-req-id',
    );

    T2->isa_ok($req,
        'Temporalio::Proto::Api::Workflowservice::V1::ResetWorkflowExecutionRequest');
    T2->is($req->namespace, 'ns-test', 'namespace from client');
    T2->is($req->workflow_execution->workflow_id, 'wf-reset', 'workflow_id');
    T2->is($req->workflow_execution->run_id, 'run-abc', 'run_id');
    T2->is($req->reason, 'because', 'reason');
    T2->is($req->workflow_task_finish_event_id, 7, 'finish event id');
    T2->is($req->request_id, 'fixed-req-id', 'request_id passthrough');
    T2->is($req->identity, 'id-test@host', 'identity from client');
    # reset_reapply_type all_eligible == 3 (enums/v1/reset.proto)
    T2->is($req->reset_reapply_type, 3, 'reset_reapply_type all_eligible -> 3');
    # exclude types signal(1) + update(2)
    T2->is($req->reset_reapply_exclude_types, [ 1, 2 ],
        'exclude types map to [signal=1, update=2]');
});

# ---------------------------------------------------------------------------
# T-reset-2: enum mapping table + default request_id (fresh UUID)
# ---------------------------------------------------------------------------
T2->subtest('reset_reapply_type enum mapping (T-reset-2)' => sub {
    my $handle = make_handle;
    my %want = (signal => 1, none => 2, all_eligible => 3);
    for my $name (sort keys %want) {
        my $req = $handle->_build_reset_request(
            workflow_task_finish_event_id => 1,
            reset_reapply_type            => $name,
        );
        T2->is($req->reset_reapply_type, $want{$name},
            "reset_reapply_type '$name' -> $want{$name}");
    }

    # A bare numeric value passes through unchanged.
    my $num = $handle->_build_reset_request(
        workflow_task_finish_event_id => 1,
        reset_reapply_type            => 2,
    );
    T2->is($num->reset_reapply_type, 2, 'numeric reset_reapply_type passthrough');

    # Default request_id is a fresh non-empty UUID.
    my $defaulted = $handle->_build_reset_request(
        workflow_task_finish_event_id => 1,
    );
    T2->ok(length($defaulted->request_id) > 0, 'request_id defaults to a UUID');
});

T2->subtest('reset_reapply_exclude_types enum mapping (T-reset-2)' => sub {
    my $handle = make_handle;
    my %want = (signal => 1, update => 2, nexus => 3);
    for my $name (sort keys %want) {
        my $req = $handle->_build_reset_request(
            workflow_task_finish_event_id => 1,
            reset_reapply_exclude_types   => [ $name ],
        );
        T2->is($req->reset_reapply_exclude_types, [ $want{$name} ],
            "exclude type '$name' -> $want{$name}");
    }
});

# ---------------------------------------------------------------------------
# Pre-RPC Argument guards (spec 30.1: missing event id / bad enum string)
# ---------------------------------------------------------------------------
T2->subtest('missing workflow_task_finish_event_id raises Argument' => sub {
    my $handle = make_handle;
    my $err = exception_from(sub {
        $handle->_build_reset_request(reason => 'x');
    });
    T2->ok(is_argument_exc($err), 'missing event id -> Argument')
        or T2->diag('got: ' . ($err // 'no exception'));
    T2->like("$err", qr/workflow_task_finish_event_id/,
        'message names the missing field');
});

T2->subtest('bad reset_reapply_type string raises Argument' => sub {
    my $handle = make_handle;
    my $err = exception_from(sub {
        $handle->_build_reset_request(
            workflow_task_finish_event_id => 1,
            reset_reapply_type            => 'bogus',
        );
    });
    T2->ok(is_argument_exc($err), 'bad reapply type -> Argument')
        or T2->diag('got: ' . ($err // 'no exception'));
    T2->like("$err", qr/bogus/, 'message names the bad value');
});

T2->subtest('bad reset_reapply_exclude_types string raises Argument' => sub {
    my $handle = make_handle;
    my $err = exception_from(sub {
        $handle->_build_reset_request(
            workflow_task_finish_event_id => 1,
            reset_reapply_exclude_types   => [ 'signal', 'nope' ],
        );
    });
    T2->ok(is_argument_exc($err), 'bad exclude type -> Argument')
        or T2->diag('got: ' . ($err // 'no exception'));
    T2->like("$err", qr/nope/, 'message names the bad value');
});

# ---------------------------------------------------------------------------
# Client->reset_workflow delegates to a handle built from id/run_id
# ---------------------------------------------------------------------------
T2->subtest('Client->reset_workflow builds the same request via a handle' => sub {
    my $client = make_client;
    my $req = $client->_build_reset_workflow_request(
        'wf-xyz', 'run-1',
        workflow_task_finish_event_id => 9,
        reset_reapply_type            => 'none',
    );
    T2->is($req->workflow_execution->workflow_id, 'wf-xyz', 'workflow_id');
    T2->is($req->workflow_execution->run_id, 'run-1', 'run_id');
    T2->is($req->workflow_task_finish_event_id, 9, 'finish event id');
    T2->is($req->reset_reapply_type, 2, 'none -> 2');
});

T2->done_testing;
