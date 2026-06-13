# ABOUTME: Table-driven tests for the spec section 7.5 gRPC status -> exception
# ABOUTME: mapping (Temporalio::Core::Callback::rpc_error_for), including the
# ABOUTME: NOT_FOUND/ALREADY_EXISTS/FAILED_PRECONDITION special cases.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();
use Temporalio::Core::Callback ();
use Temporalio::Core::Proto ();

Temporalio::Core::Proto->load;

my $STATUS_CLASS  = Temporalio::Core::Proto::resolve('google.rpc.Status');
my $ALREADY_CLASS = Temporalio::Core::Proto::resolve(
    'temporal.api.errordetails.v1.WorkflowExecutionAlreadyStartedFailure');

sub map_error (%args) {
    return Temporalio::Core::Callback::rpc_error_for(
        message => 'boom',
        rpc     => 'DescribeNamespace',
        %args,
    );
}

# Every plain row of the spec section 7.5 table (status code -> class), plus
# the catch-all rows. status_name is the canonical lowercase gRPC name
# (verified against sdk-python service.py RPCStatusCode).
my @table = (
    # [ code, rpc, expected class, expected status_name (RpcError family) ]
    [ 1,  'DescribeNamespace', 'Temporalio::Exception::Cancelled',            undef ],
    [ 2,  'DescribeNamespace', 'Temporalio::Exception::RpcError',             'unknown' ],
    [ 3,  'DescribeNamespace', 'Temporalio::Exception::RpcError',             'invalid_argument' ],
    [ 4,  'DescribeNamespace', 'Temporalio::Exception::RpcTimeout',           'deadline_exceeded' ],
    [ 5,  'DescribeNamespace', 'Temporalio::Exception::NamespaceNotFound',    undef ],
    [ 5,  'DescribeWorkflowExecution', 'Temporalio::Exception::WorkflowNotFound', undef ],
    [ 5,  'RespondActivityTaskCompleted', 'Temporalio::Exception::ActivityNotFound', undef ],
    [ 6,  'DescribeNamespace', 'Temporalio::Exception::RpcError',             'already_exists' ],
    [ 7,  'DescribeNamespace', 'Temporalio::Exception::RpcPermissionDenied',  'permission_denied' ],
    [ 8,  'DescribeNamespace', 'Temporalio::Exception::RpcResourceExhausted', 'resource_exhausted' ],
    [ 9,  'QueryWorkflow',     'Temporalio::Exception::QueryRejected',        undef ],
    [ 9,  'DescribeNamespace', 'Temporalio::Exception::RpcError',             'failed_precondition' ],
    [ 10, 'DescribeNamespace', 'Temporalio::Exception::RpcError',             'aborted' ],
    [ 11, 'DescribeNamespace', 'Temporalio::Exception::RpcError',             'out_of_range' ],
    [ 12, 'DescribeNamespace', 'Temporalio::Exception::RpcError',             'unimplemented' ],
    [ 13, 'DescribeNamespace', 'Temporalio::Exception::RpcError',             'internal' ],
    [ 14, 'DescribeNamespace', 'Temporalio::Exception::RpcError',             'unavailable' ],
    [ 15, 'DescribeNamespace', 'Temporalio::Exception::RpcError',             'data_loss' ],
    [ 16, 'DescribeNamespace', 'Temporalio::Exception::RpcUnauthenticated',   'unauthenticated' ],
);

T2->subtest('spec 7.5 table rows map to the right classes' => sub {
    for my $row (@table) {
        my ($code, $rpc, $class, $name) = @$row;
        my $exc = map_error(status_code => $code, rpc => $rpc);
        T2->ok(
            Scalar::Util::blessed($exc) && ref($exc) eq $class,
            "code $code on $rpc maps to $class",
        ) or T2->diag('got: ' . (ref($exc) || $exc));
        T2->is($exc->message, 'boom', "code $code threads the message");
        if ($exc->isa('Temporalio::Exception::RpcError')) {
            T2->is($exc->status_code, $code, "code $code carries status_code");
            T2->is($exc->status_name, $name, "code $code carries status_name");
        }
    }
});

T2->subtest('RpcError subclasses keep the isa chain (spec 6.2, T-exc-4)' => sub {
    for my $code (4, 7, 8, 16) {
        my $exc = map_error(status_code => $code);
        T2->ok($exc->isa('Temporalio::Exception::RpcError'),
            "code $code isa RpcError");
    }
    my $nf = map_error(status_code => 5);
    T2->ok($nf->isa('Temporalio::Exception::NotFound'),
        'NOT_FOUND isa the NotFound base');
});

T2->subtest('catch-all: unknown code and code 0 with a message' => sub {
    my $exc = map_error(status_code => 99);
    T2->ok(ref($exc) eq 'Temporalio::Exception::RpcError',
        'unmapped code falls back to RpcError');
    T2->is($exc->status_code, 99, 'unmapped code keeps status_code');
    T2->is($exc->status_name, undef, 'unmapped code has no status name');

    # client.rs: "Status code may still be 0 with a failure message" - a
    # non-gRPC failure (e.g. a cancelled call) is still an RpcError.
    my $zero = map_error(status_code => 0);
    T2->ok(ref($zero) eq 'Temporalio::Exception::RpcError',
        'code 0 with a failure message is an RpcError');
    T2->is($zero->status_code, 0, 'code 0 keeps status_code 0');
    T2->is($zero->status_name, undef, 'code 0 has no status name');
});

T2->subtest('failure_details decode as google.rpc.Status when present' => sub {
    my $status_bytes = $STATUS_CLASS->new({
        code    => 14,
        message => 'server says no',
    })->encode;

    my $exc = map_error(status_code => 14, details => $status_bytes);
    T2->ok(defined $exc->details, 'details decoded');
    T2->isa_ok($exc->details, $STATUS_CLASS);
    T2->is($exc->details->code, 14, 'decoded Status code survives');
    T2->is($exc->details->message, 'server says no',
        'decoded Status message survives');

    # The bridge sends an EMPTY (non-null) details byte array when tonic has
    # no grpc-status-details-bin; absent and empty both mean "no details".
    T2->is(map_error(status_code => 14, details => '')->details,
        undef, 'empty details mean no details');
    T2->is(map_error(status_code => 14)->details,
        undef, 'absent details mean no details');

    # Garbage details must never turn an error into a different death.
    my $garbage = map_error(status_code => 14, details => "\xff\xff\xff");
    T2->ok(ref($garbage) eq 'Temporalio::Exception::RpcError',
        'undecodable details still map');
});

T2->subtest('ALREADY_EXISTS on start_workflow unpacks WorkflowAlreadyStarted' => sub {
    # Mirrors sdk-python client/_impl.py and sdk-ruby implementation.rb: the
    # google.rpc.Status details[0] Any unpacks as the errordetails failure.
    my $details = $STATUS_CLASS->new({
        code    => 6,
        message => 'Workflow execution already started',
        details => [
            {
                type_url => 'type.googleapis.com/temporal.api.errordetails.v1.WorkflowExecutionAlreadyStartedFailure',
                value    => $ALREADY_CLASS->new({
                    start_request_id => 'req-1',
                    run_id           => 'run-1',
                })->encode,
            },
        ],
    })->encode;

    for my $rpc (qw(StartWorkflowExecution SignalWithStartWorkflowExecution)) {
        my $exc = map_error(
            status_code   => 6,
            rpc           => $rpc,
            details       => $details,
            workflow_id   => 'wf-1',
            workflow_type => 'MyWorkflow',
        );
        T2->ok(ref($exc) eq 'Temporalio::Exception::WorkflowAlreadyStarted',
            "code 6 on $rpc maps to WorkflowAlreadyStarted")
            or T2->diag('got: ' . (ref($exc) || $exc));
        T2->is($exc->run_id, 'run-1', 'run_id unpacked from the details');
        T2->is($exc->workflow_id, 'wf-1', 'workflow_id from the caller context');
        T2->is($exc->workflow_type, 'MyWorkflow', 'workflow_type from the caller context');
    }

    # Without unpackable details the reference SDKs re-raise the RPC error.
    my $plain = map_error(status_code => 6, rpc => 'StartWorkflowExecution');
    T2->ok(ref($plain) eq 'Temporalio::Exception::RpcError',
        'code 6 without details falls back to RpcError');
    T2->is($plain->status_name, 'already_exists', 'fallback keeps the status name');

    # An Any of a DIFFERENT type must not be unpacked.
    my $wrong = $STATUS_CLASS->new({
        code    => 6,
        details => [ { type_url => 'type.googleapis.com/other.Thing', value => '' } ],
    })->encode;
    my $other = map_error(
        status_code => 6, rpc => 'StartWorkflowExecution', details => $wrong);
    T2->ok(ref($other) eq 'Temporalio::Exception::RpcError',
        'mismatched Any type falls back to RpcError');
});

T2->done_testing;
