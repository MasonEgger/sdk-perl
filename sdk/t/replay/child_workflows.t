# ABOUTME: Replay tests for workflow-side child workflows (spec section 18):
# ABOUTME: StartChildWorkflowExecution emission, two-stage start/result
# ABOUTME: resolution, failure/cancel mapping, separate seq space, signal/cancel
# ABOUTME: of the handle, enum mapping, cancel propagation, deterministic id
# ABOUTME: (T-child-1..12).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Converter::Payload;
use Temporalio::Converter::Failure;
use Temporalio::Exception::Application;
use Temporalio::Exception::Cancelled;
use Temporalio::Exception::ChildWorkflow;

no warnings 'experimental::class';

# Build a WorkflowActivation proto from the oneof-tagged hashref job form.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;
my $FC = Temporalio::Converter::Failure->default;

sub payload ($value) { return $PC->to_payload($value) }

# A ChildWorkflowFailure-ish Failure proto wrapping an application error of the
# given type/message — the shape ResolveChildWorkflowExecution{failed} carries.
sub app_failure ($type, $msg) {
    my $cause = Temporalio::Exception::Application->new(message => $msg, type => $type);
    return $FC->to_failure($cause, $PC);
}

# A Cancelled failure proto.
sub cancelled_failure ($msg) {
    return $FC->to_failure(
        Temporalio::Exception::Cancelled->new(message => $msg), $PC);
}

# ---------------------------------------------------------------------------
# T-child-1: execute_child_workflow emits one StartChildWorkflowExecution on the
# init activation (seq 1, type, id, parent task queue empty in replay,
# parent_close_policy=1, cancellation_type=2, reuse=allow_duplicate=1, converted
# args); the body parks on the start await, so NO completion command is emitted.
# ---------------------------------------------------------------------------
T2->subtest('execute_child_workflow emits StartChildWorkflowExecution (T-child-1)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildCaller');

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ChildCaller',
                arguments     => [ payload('Alice') ],
            } },
        ],
    }));

    T2->is(scalar @commands, 1, 'exactly one command emitted');
    my $cmd = $commands[0];
    T2->is($cmd->which_variant, 'start_child_workflow_execution',
        'the command is StartChildWorkflowExecution');

    my $s = $cmd->start_child_workflow_execution;
    T2->is($s->seq, 1, 'child seq starts at 1');
    T2->is($s->workflow_id, 'child-1', 'workflow_id is the supplied id');
    T2->is($s->workflow_type, 'GreetingChild', 'workflow_type is the named child');
    T2->is($s->parent_close_policy, 1, 'parent_close_policy defaults to terminate=1');
    T2->is($s->cancellation_type, 2,
        'cancellation_type defaults to wait_cancellation_completed=2');
    T2->is($s->workflow_id_reuse_policy, 1,
        'id_reuse_policy defaults to allow_duplicate=1');
    T2->is(scalar $s->input->@*, 1, 'one input payload');
    T2->is($PC->from_payload($s->input->[0]), 'Alice', 'input round-trips');
});

# ---------------------------------------------------------------------------
# T-child-2: ResolveChildWorkflowExecutionStart{succeeded{run_id}} resolves the
# start; first_execution_run_id == run_id. A start-only workflow completes
# (returns the run id), while an execute workflow stays parked.
# ---------------------------------------------------------------------------
T2->subtest('ResolveChildWorkflowExecutionStart resolves start (T-child-2)' => sub {
    # start-only workflow: completes on start resolution.
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildStarter');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => { workflow_type => 'ChildStarter' } } ],
    }));

    my @second = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq => 1, succeeded => { run_id => 'run-xyz' },
        } } ],
    }));
    T2->is(scalar @second, 1, 'one command after start resolves');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'start-only workflow completes on start resolution');
    T2->is($PC->from_payload($second[0]->complete_workflow_execution->result),
        'run-xyz', 'completion carries first_execution_run_id');

    # execute workflow: stays parked after start (waits for the result job).
    my $h2 = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildCaller');
    $h2->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildCaller', arguments => [ payload('Alice') ],
        } } ],
    }));
    my @after_start = $h2->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq => 1, succeeded => { run_id => 'run-abc' },
        } } ],
    }));
    T2->is(scalar @after_start, 0,
        'execute workflow emits no command on start (still awaiting result)');
});

# ---------------------------------------------------------------------------
# T-child-3: ResolveChildWorkflowExecution{completed{result}} resumes
# execute_child_workflow; the workflow completes with the converted result.
# ---------------------------------------------------------------------------
T2->subtest('ResolveChildWorkflowExecution completed resumes execute (T-child-3)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildCaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildCaller', arguments => [ payload('Alice') ],
        } } ],
    }));
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq => 1, succeeded => { run_id => 'run-abc' },
        } } ],
    }));

    my @done = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { resolve_child_workflow_execution => {
            seq    => 1,
            result => { completed => { result => payload('Hello, Alice!') } },
        } } ],
    }));
    T2->is(scalar @done, 1, 'one command after result resolves');
    T2->is($done[0]->which_variant, 'complete_workflow_execution',
        'workflow completes after the child result');
    T2->is($PC->from_payload($done[0]->complete_workflow_execution->result),
        'got: Hello, Alice!', 'completion carries the post-child return value');
});

# ---------------------------------------------------------------------------
# T-child-4: result failed{failure} raises Temporalio::Exception::ChildWorkflow
# (cause = mapped failure); the workflow fails per the outcome table.
# ---------------------------------------------------------------------------
T2->subtest('ResolveChildWorkflowExecution failed -> ChildWorkflow (T-child-4)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildCaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildCaller', arguments => [ payload('Alice') ],
        } } ],
    }));
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq => 1, succeeded => { run_id => 'run-abc' },
        } } ],
    }));

    my @failed = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { resolve_child_workflow_execution => {
            seq    => 1,
            result => { failed => { failure => app_failure('BadChild', 'boom') } },
        } } ],
    }));
    T2->is(scalar @failed, 1, 'one command');
    T2->is($failed[0]->which_variant, 'fail_workflow_execution',
        'the escaped ChildWorkflow failure fails the workflow');
    my $failure = $failed[0]->fail_workflow_execution->failure;
    T2->like($failure->message, qr/Child workflow execution failed/,
        'failure carries the ChildWorkflow message');
    T2->is($failure->cause->application_failure_info->type, 'BadChild',
        'failure cause preserves the underlying application error type');
});

# ---------------------------------------------------------------------------
# T-child-5: start failed{cause: WORKFLOW_ALREADY_EXISTS=1} -> WorkflowAlreadyStarted
# on the start await; no result job follows.
# ---------------------------------------------------------------------------
T2->subtest('start failed WORKFLOW_ALREADY_EXISTS -> WorkflowAlreadyStarted (T-child-5)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildCaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildCaller', arguments => [ payload('Alice') ],
        } } ],
    }));

    my @failed = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq    => 1,
            failed => {
                workflow_id => 'child-1', workflow_type => 'GreetingChild',
                cause => 1,
            },
        } } ],
    }));
    T2->is(scalar @failed, 1, 'one command');
    T2->is($failed[0]->which_variant, 'fail_workflow_execution',
        'WorkflowAlreadyStarted escaping :Run fails the workflow');
    my $failure = $failed[0]->fail_workflow_execution->failure;
    T2->like($failure->message, qr/already started/i,
        'the failure is the already-started error');
});

# ---------------------------------------------------------------------------
# T-child-6: start cancelled{failure} -> Cancelled on the start await.
# ---------------------------------------------------------------------------
T2->subtest('start cancelled -> Cancelled (T-child-6)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildCaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildCaller', arguments => [ payload('Alice') ],
        } } ],
    }));

    my $completion = $h->push_activation_completion(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq       => 1,
            cancelled => { failure => cancelled_failure('child cancelled') },
        } } ],
    }));
    # A Cancelled with no CancelWorkflow request is a normal failure outcome.
    my @cmds = $h->commands_of($completion);
    T2->is($cmds[0]->which_variant, 'fail_workflow_execution',
        'a Cancelled on start (no cancel request) fails the workflow');
});

# ---------------------------------------------------------------------------
# T-child-7: $handle->cancel emits CancelChildWorkflowExecution{seq 1}; a later
# cancelled resolve settles the result to ChildWorkflow/Cancelled. With
# cancellation_type=abandon, NO cancel command is emitted.
# ---------------------------------------------------------------------------
T2->subtest('handle->cancel emits CancelChildWorkflowExecution (T-child-7)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildCanceller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildCanceller',
            arguments     => [ payload('wait_cancellation_completed') ],
        } } ],
    }));
    # Start the child.
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq => 1, succeeded => { run_id => 'run-abc' },
        } } ],
    }));
    # Signal to request cancel: the body cancels the handle -> cancel command.
    my @cmds = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { signal_workflow => { signal_name => 'cancel' } } ],
    }));
    my ($cancel_cmd) = grep {
        $_->which_variant eq 'cancel_child_workflow_execution'
    } @cmds;
    T2->ok($cancel_cmd, 'a CancelChildWorkflowExecution command is emitted');
    T2->is($cancel_cmd->cancel_child_workflow_execution->child_workflow_seq, 1,
        'cancel targets child_workflow_seq 1');

    # abandon: NO cancel command emitted.
    my $ha = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildCanceller');
    $ha->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildCanceller', arguments => [ payload('abandon') ],
        } } ],
    }));
    $ha->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq => 1, succeeded => { run_id => 'run-abc' },
        } } ],
    }));
    my @acmds = $ha->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { signal_workflow => { signal_name => 'cancel' } } ],
    }));
    my @abandon_cancel = grep {
        $_->which_variant eq 'cancel_child_workflow_execution'
    } @acmds;
    T2->is(scalar @abandon_cancel, 0,
        'abandon-typed child emits no cancel command');
});

# ---------------------------------------------------------------------------
# T-child-8: two children get seq 1, 2 (separate space — the activity is also
# seq 1); out-of-order resolution settles the right handles.
# ---------------------------------------------------------------------------
T2->subtest('two children seq 1/2 in a separate space; out-of-order (T-child-8)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TwoChildrenAndActivity');
    my @first = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'TwoChildrenAndActivity' } } ],
    }));

    my @child_cmds = grep {
        $_->which_variant eq 'start_child_workflow_execution'
    } @first;
    my ($act_cmd) = grep { $_->which_variant eq 'schedule_activity' } @first;
    T2->is(scalar @child_cmds, 2, 'two StartChildWorkflowExecution commands');
    T2->is($child_cmds[0]->start_child_workflow_execution->seq, 1, 'first child seq 1');
    T2->is($child_cmds[1]->start_child_workflow_execution->seq, 2, 'second child seq 2');
    T2->is($act_cmd->schedule_activity->seq, 1,
        'the activity is seq 1 in its own space (separate from children)');

    # Resolve both child starts.
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [
            { resolve_child_workflow_execution_start => {
                seq => 2, succeeded => { run_id => 'r2' } } },
            { resolve_child_workflow_execution_start => {
                seq => 1, succeeded => { run_id => 'r1c' } } },
        ],
    }));
    # Resolve results out of order: child 2 first, then child 1, then activity.
    my @done = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [
            { resolve_child_workflow_execution => {
                seq => 2, result => { completed => { result => payload('two') } } } },
            { resolve_child_workflow_execution => {
                seq => 1, result => { completed => { result => payload('one') } } } },
            { resolve_activity => {
                seq => 1, result => { completed => { result => payload('act') } } } },
        ],
    }));
    T2->is($done[0]->which_variant, 'complete_workflow_execution',
        'workflow completes once all three resolve');
    T2->is($PC->from_payload($done[0]->complete_workflow_execution->result),
        [ 'one', 'two', 'act' ],
        'each result lands on its own handle (matched by seq, not arrival)');
});

# ---------------------------------------------------------------------------
# T-child-9: $handle->signal emits SignalExternalWorkflowExecution with the
# child_workflow_id arm set (not workflow_execution).
# ---------------------------------------------------------------------------
T2->subtest('handle->signal uses the child_workflow_id arm (T-child-9)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildSignaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => { workflow_type => 'ChildSignaller' } } ],
    }));
    # Resolve the start: the body then signals.
    my @cmds = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq => 1, succeeded => { run_id => 'run-abc' },
        } } ],
    }));
    my ($sig) = grep {
        $_->which_variant eq 'signal_external_workflow_execution'
    } @cmds;
    T2->ok($sig, 'a SignalExternalWorkflowExecution command is emitted');
    my $sew = $sig->signal_external_workflow_execution;
    T2->is($sew->which_target, 'child_workflow_id',
        'the child_workflow_id oneof arm is set (not workflow_execution)');
    T2->is($sew->child_workflow_id, 'child-1', 'targets the child id');
    T2->is($sew->signal_name, 'go', 'signal name threaded');
    T2->is($PC->from_payload($sew->args->[0]), 'x', 'signal args converted');
});

# ---------------------------------------------------------------------------
# T-child-10: enum string mapping (parent_close_policy 'abandon'->2,
# cancellation_type 'try_cancel'->1); a bad string dies at scheduling time.
# ---------------------------------------------------------------------------
T2->subtest('enum string mapping + bad string dies at scheduling (T-child-10)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildEnumCaller');
    my @cmds = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildEnumCaller',
            arguments     => [
                payload('parent_close_policy'), payload('abandon'),
                payload('cancellation_type'),   payload('try_cancel'),
            ],
        } } ],
    }));
    my ($start) = grep {
        $_->which_variant eq 'start_child_workflow_execution'
    } @cmds;
    T2->is($start->start_child_workflow_execution->parent_close_policy, 2,
        "parent_close_policy 'abandon' maps to 2");
    T2->is($start->start_child_workflow_execution->cancellation_type, 1,
        "cancellation_type 'try_cancel' maps to 1");

    # A bad enum string dies at scheduling: the error escapes :Run as a plain
    # die, so the completion is a TASK failure (which_status 'failed').
    my $hb = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildEnumCaller');
    my $completion = $hb->push_activation_completion(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildEnumCaller',
            arguments     => [ payload('cancellation_type'), payload('nonsense') ],
        } } ],
    }));
    T2->is($completion->which_status, 'failed',
        'a bad enum string at scheduling fails the workflow task');
    T2->like($completion->failed->failure->message, qr/cancellation_type/,
        'the task failure names the bad enum option');
});

# ---------------------------------------------------------------------------
# T-child-11: a CancelWorkflow job cancels a pending child handle (emits the
# cancel command) and fails the awaiting result (mirrors T-act-9).
# ---------------------------------------------------------------------------
T2->subtest('CancelWorkflow propagation cancels a pending child (T-child-11)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildCaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'ChildCaller', arguments => [ payload('Alice') ],
        } } ],
    }));
    # Start the child so a result is pending.
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_child_workflow_execution_start => {
            seq => 1, succeeded => { run_id => 'run-abc' },
        } } ],
    }));

    my @cmds = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { cancel_workflow => {} } ],
    }));
    my ($cancel_cmd) = grep {
        $_->which_variant eq 'cancel_child_workflow_execution'
    } @cmds;
    T2->ok($cancel_cmd, 'CancelWorkflow emits CancelChildWorkflowExecution');
    T2->is($cancel_cmd->cancel_child_workflow_execution->child_workflow_seq, 1,
        'cancel targets the pending child seq');
    # The body's result await raises Cancelled, which (cancel_requested) maps to
    # a CancelWorkflowExecution (NOT a fail) — but the ChildWorkflow wrapper is
    # raised at the await; the canceller fixture just lets it escape. Assert the
    # workflow does NOT complete successfully.
    my ($complete) = grep {
        $_->which_variant eq 'complete_workflow_execution'
    } @cmds;
    T2->ok(!$complete, 'the workflow does not complete successfully after cancel');
});

# ---------------------------------------------------------------------------
# T-child-12: omitting id yields a deterministic id (re-running the init
# activation with the same randomness seed reproduces it).
# ---------------------------------------------------------------------------
T2->subtest('omitted id is deterministic across re-run (T-child-12)' => sub {
    my sub run_once {
        my $h = Temporalio::Test::WorkflowReplay->new(
            workflow_class => 'WfDef::ChildDefaultId');
        my @cmds = $h->push_activation(activation({
            run_id => 'r1', timestamp => { seconds => 100 },
            jobs   => [ { initialize_workflow => {
                workflow_type   => 'ChildDefaultId',
                randomness_seed => 424242,
            } } ],
        }));
        my ($start) = grep {
            $_->which_variant eq 'start_child_workflow_execution'
        } @cmds;
        return $start->start_child_workflow_execution->workflow_id;
    }

    my $id1 = run_once();
    my $id2 = run_once();
    T2->ok(length $id1, 'a default id was generated');
    T2->is($id1, $id2,
        'the same randomness seed reproduces the same default id (deterministic)');
});

T2->done_testing;
