# ABOUTME: Weak-ref liveness tests for the start-future ownership cycle (spec
# ABOUTME: R29, finding L5): resolving a handle's start future with the handle
# ABOUTME: itself must not pin the handle in an uncollectable cycle.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util qw(weaken);

use Temporalio::Workflow::Future ();
use Temporalio::Workflow::ChildWorkflowHandle ();
use Temporalio::Workflow::NexusOperationHandle ();

# Finding L5 (spec R29): ChildWorkflowHandle.pm:58 and
# NexusOperationHandle.pm:64 resolve the start future with the owning handle
# itself, so the future's stored result held the handle STRONGLY while the
# handle's start_future field (and the Runner-installed on_cancel/on_signal
# closures, which capture the futures lexically at the construction sites in
# Runner::start_child_workflow / Runner::start_operation) held the future.
# That handle <-> start-future cycle was uncollectable: it pinned the handle,
# both its futures, and everything the closures captured, once per child /
# nexus start. Required behavior: the resolved start future holds the handle
# only weakly (Temporalio::Workflow::Future::done_weak), so dropping the
# caller's refs lets the handle's DESTROY run even while the future lives.
#
# Adapted from probe verify-45/runner-misc/probe_l5_cycle.pl (ephemeral
# scratch, no longer on disk); the weak-ref liveness check is the probe's.

T2->subtest('ChildWorkflowHandle: resolved start future does not pin the handle' => sub {
    my $start_future  = Temporalio::Workflow::Future->new;
    my $result_future = Temporalio::Workflow::Future->new;

    # Mirror Runner::start_child_workflow: the on_cancel / on_signal hooks
    # capture the futures lexically, so the handle also reaches the start
    # future through its closures, not only through its start_future field.
    my $handle = Temporalio::Workflow::ChildWorkflowHandle->new(
        id                 => 'child-l5',
        child_workflow_seq => 1,
        start_future       => $start_future,
        result_future      => $result_future,
        on_cancel          => sub ($h) {
            my @captured = ($start_future, $result_future);
            return;
        },
        on_signal          => sub ($h, $name, %opts) {
            my @captured = ($start_future, $result_future);
            return Temporalio::Workflow::Future->new;
        },
    );

    # The Runner's ResolveChildWorkflowExecutionStart{succeeded} path.
    $handle->_resolve_started('run-id-l5');

    T2->is($handle->first_execution_run_id, 'run-id-l5',
        'run id recorded by _resolve_started');
    T2->ref_is(scalar $start_future->get, $handle,
        'awaiting caller still receives the handle from the start future');

    # The L5 assertion: drop the caller's strong refs while the start future
    # (the value start_child_workflow returned) is still alive, and the
    # handle must be collected -- the future's back-reference is weak.
    weaken(my $weak_handle = $handle);
    undef $handle;

    T2->ok(!defined $weak_handle,
        'handle DESTROY runs once caller refs drop, start future still live');
    T2->is(scalar $start_future->get, undef,
        'resolved start future held only a weak back-reference');

    # And nothing residual: dropping the test's future refs collects them.
    weaken(my $weak_start = $start_future);
    undef $start_future;
    undef $result_future;
    T2->ok(!defined $weak_start,
        'start future collected once all refs drop (no residual cycle)');
});

T2->subtest('NexusOperationHandle: resolved start future does not pin the handle' => sub {
    my $start_future  = Temporalio::Workflow::Future->new;
    my $result_future = Temporalio::Workflow::Future->new;

    # Mirror Runner::start_operation: on_cancel captures the futures.
    my $handle = Temporalio::Workflow::NexusOperationHandle->new(
        nexus_operation_seq => 1,
        endpoint            => 'ep-l5',
        service             => 'svc-l5',
        operation           => 'op-l5',
        start_future        => $start_future,
        result_future       => $result_future,
        on_cancel           => sub ($h) {
            my @captured = ($start_future, $result_future);
            return;
        },
    );

    # The Runner's ResolveNexusOperationStart path (async arm: token set).
    $handle->_resolve_started('token-l5');

    T2->is($handle->operation_token, 'token-l5',
        'operation token recorded by _resolve_started');
    T2->ref_is(scalar $start_future->get, $handle,
        'awaiting caller still receives the handle from the start future');

    weaken(my $weak_handle = $handle);
    undef $handle;

    T2->ok(!defined $weak_handle,
        'handle DESTROY runs once caller refs drop, start future still live');
    T2->is(scalar $start_future->get, undef,
        'resolved start future held only a weak back-reference');

    weaken(my $weak_start = $start_future);
    undef $start_future;
    undef $result_future;
    T2->ok(!defined $weak_start,
        'start future collected once all refs drop (no residual cycle)');
});

T2->done_testing;
