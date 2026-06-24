# ABOUTME: Replay tests for workflow-side Nexus operations, caller side (spec
# ABOUTME: section 26): ScheduleNexusOperation emission, two-stage start/result
# ABOUTME: resolution (async token vs started_sync), failure/timeout/cancel
# ABOUTME: mapping, separate seq space, $handle->cancel + abandon + pre-scheduled
# ABOUTME: cancel, unknown-seq non-determinism (T-nexus-1..9).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Converter::Payload;
use Temporalio::Converter::Failure;
use Temporalio::Exception::Application;
use Temporalio::Exception::Cancelled;
use Temporalio::Exception::Timeout;
use Temporalio::Exception::NexusOperation;

no warnings 'experimental::class';

# Build a WorkflowActivation proto from the oneof-tagged hashref job form.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;
my $FC = Temporalio::Converter::Failure->default;

sub payload ($value) { return $PC->to_payload($value) }

# A nexus_operation_execution_failure Failure whose `cause` is the inner mapped
# failure — the wire shape ResolveNexusOperation{failed/cancelled/timed_out}
# carries (spec section 26.4). $inner is a Temporalio::Exception::*.
sub nexus_failure ($inner) {
    my $exc = Temporalio::Exception::NexusOperation->new(
        message   => 'Nexus operation error',
        endpoint  => 'my-endpoint',
        service   => 'my-service',
        operation => 'say-hello',
        cause     => $inner,
    );
    return $FC->to_failure($exc, $PC);
}

# A bare inner Failure (e.g. for the resolve-start failed arm).
sub app_failure ($type, $msg) {
    return $FC->to_failure(
        Temporalio::Exception::Application->new(message => $msg, type => $type),
        $PC);
}

# ---------------------------------------------------------------------------
# T-nexus-1: execute_operation emits one ScheduleNexusOperation on the init
# activation (seq 1, endpoint/service/operation, single converted input,
# cancellation_type=0 default, no timeouts unless set); the body parks on the
# start await, so NO completion command is emitted.
# ---------------------------------------------------------------------------
T2->subtest('execute_operation emits ScheduleNexusOperation (T-nexus-1)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusCaller');

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'NexusCaller',
                arguments     => [ payload('world') ],
            } },
        ],
    }));

    T2->is(scalar @commands, 1, 'exactly one command emitted');
    my $cmd = $commands[0];
    T2->is($cmd->which_variant, 'schedule_nexus_operation',
        'the command is ScheduleNexusOperation');

    my $s = $cmd->schedule_nexus_operation;
    T2->is($s->seq, 1, 'nexus seq starts at 1');
    T2->is($s->endpoint, 'my-endpoint', 'endpoint passed through');
    T2->is($s->service, 'my-service', 'service passed through');
    T2->is($s->operation, 'say-hello', 'operation passed through');
    T2->is($s->cancellation_type, 0,
        'cancellation_type defaults to wait_cancellation_completed=0');
    # SINGLE input Payload (not a repeated list).
    T2->is($PC->from_payload($s->input), 'world', 'single input round-trips');
});

# ---------------------------------------------------------------------------
# T-nexus-2: started_sync + a same-activation completed resolves
# execute_operation; operation_token is undef (sync op), result is the converted
# completed payload (the primary sync_success case, "Hello, world!", no Started).
# ---------------------------------------------------------------------------
T2->subtest('started_sync + same-activation completed -> sync result (T-nexus-2)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusCaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'NexusCaller', arguments => [ payload('world') ],
        } } ],
    }));

    # Both the started_sync job AND its completed result land in ONE activation.
    my @done = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [
            { resolve_nexus_operation_start => { seq => 1, started_sync => 1 } },
            { resolve_nexus_operation => {
                seq => 1, result => { completed => payload('Hello, world!') },
            } },
        ],
    }));
    T2->is(scalar @done, 1, 'one command after the sync resolve');
    T2->is($done[0]->which_variant, 'complete_workflow_execution',
        'workflow completes on the same-activation sync resolution');
    T2->is($PC->from_payload($done[0]->complete_workflow_execution->result),
        'Hello, world!', 'completion carries the sync operation result');
});

# ---------------------------------------------------------------------------
# T-nexus-3: ResolveNexusOperationStart{operation_token} resolves an async start;
# a start-only workflow completes returning the token. An execute workflow stays
# parked after the start (the result job follows separately).
# ---------------------------------------------------------------------------
T2->subtest('operation_token start resolves the handle (T-nexus-3)' => sub {
    # start-only workflow: completes on start resolution, returning the token.
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusStarter');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => { workflow_type => 'NexusStarter' } } ],
    }));

    my @second = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_nexus_operation_start => {
            seq => 1, operation_token => 'tok-xyz',
        } } ],
    }));
    T2->is(scalar @second, 1, 'one command after start resolves');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'start-only workflow completes on async start resolution');
    T2->is($PC->from_payload($second[0]->complete_workflow_execution->result),
        'tok-xyz', 'completion carries the async operation_token');

    # execute workflow stays parked after the async start.
    my $h2 = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusCaller');
    $h2->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'NexusCaller', arguments => [ payload('world') ],
        } } ],
    }));
    my @after_start = $h2->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_nexus_operation_start => {
            seq => 1, operation_token => 'tok-abc',
        } } ],
    }));
    T2->is(scalar @after_start, 0,
        'execute workflow emits no command on start (still awaiting result)');
});

# ---------------------------------------------------------------------------
# T-nexus-4: an async start (operation_token) then a LATER ResolveNexusOperation
# {completed} resumes the parked execute_operation; the workflow completes with
# the converted result.
# ---------------------------------------------------------------------------
T2->subtest('async start then later completed resumes execute (T-nexus-4)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusCaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'NexusCaller', arguments => [ payload('world') ],
        } } ],
    }));
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_nexus_operation_start => {
            seq => 1, operation_token => 'tok-1',
        } } ],
    }));
    my @done = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { resolve_nexus_operation => {
            seq => 1, result => { completed => payload('async-result') },
        } } ],
    }));
    T2->is(scalar @done, 1, 'one command after the terminal resolve');
    T2->is($done[0]->which_variant, 'complete_workflow_execution',
        'execute completes on the later terminal resolution');
    T2->is($PC->from_payload($done[0]->complete_workflow_execution->result),
        'async-result', 'completion carries the async result');
});

# ---------------------------------------------------------------------------
# T-nexus-5: ResolveNexusOperation{failed} fails the await with a
# NexusOperation exception whose cause is the mapped Application error; it bubbles
# out of :Run as a FailWorkflowExecution.
# ---------------------------------------------------------------------------
T2->subtest('failed -> NexusOperation cause Application (T-nexus-5)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusCaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'NexusCaller', arguments => [ payload('world') ],
        } } ],
    }));
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_nexus_operation_start => {
            seq => 1, operation_token => 'tok-1',
        } } ],
    }));
    my @failed = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { resolve_nexus_operation => {
            seq    => 1,
            result => { failed => nexus_failure(
                Temporalio::Exception::Application->new(
                    message => 'boom', type => 'BadOp')) },
        } } ],
    }));
    T2->is(scalar @failed, 1, 'one command on a failed nexus operation');
    T2->is($failed[0]->which_variant, 'fail_workflow_execution',
        'a failed nexus operation bubbles out of :Run');
    my $failure = $failed[0]->fail_workflow_execution->failure;
    # The escaping exception is a NexusOperation whose cause is the Application.
    T2->is($failure->which_failure_info, 'nexus_operation_execution_failure_info',
        'outer failure is a Nexus operation failure');
    T2->ok(defined $failure->cause, 'it carries a cause');
    T2->is($failure->cause->which_failure_info, 'application_failure_info',
        'the cause is the mapped Application error');
});

# ---------------------------------------------------------------------------
# T-nexus-6: timed_out -> Timeout cause; cancelled -> Cancelled cause (both
# wrapped in NexusOperation).
# ---------------------------------------------------------------------------
T2->subtest('timed_out -> Timeout, cancelled -> Cancelled (T-nexus-6)' => sub {
    for my $case (
        [ 'timed_out',
          Temporalio::Exception::Timeout->new(message => 'too slow'),
          'timeout_failure_info' ],
        [ 'cancelled',
          Temporalio::Exception::Cancelled->new(message => 'op cancelled'),
          'canceled_failure_info' ],
    ) {
        my ($arm, $inner, $cause_info) = @$case;
        my $h = Temporalio::Test::WorkflowReplay->new(
            workflow_class => 'WfDef::NexusCaller');
        $h->push_activation(activation({
            run_id => 'r1', timestamp => { seconds => 100 },
            jobs   => [ { initialize_workflow => {
                workflow_type => 'NexusCaller', arguments => [ payload('world') ],
            } } ],
        }));
        $h->push_activation(activation({
            run_id => 'r1', timestamp => { seconds => 101 },
            jobs   => [ { resolve_nexus_operation_start => {
                seq => 1, operation_token => 'tok-1',
            } } ],
        }));
        my @failed = $h->push_activation(activation({
            run_id => 'r1', timestamp => { seconds => 102 },
            jobs   => [ { resolve_nexus_operation => {
                seq => 1, result => { $arm => nexus_failure($inner) },
            } } ],
        }));
        T2->is(scalar @failed, 1, "one command on $arm");
        T2->is($failed[0]->which_variant, 'fail_workflow_execution',
            "$arm bubbles out of :Run");
        my $failure = $failed[0]->fail_workflow_execution->failure;
        T2->is($failure->which_failure_info,
            'nexus_operation_execution_failure_info',
            "$arm outer failure is a Nexus operation failure");
        T2->is($failure->cause->which_failure_info, $cause_info,
            "$arm cause maps correctly");
    }
});

# ---------------------------------------------------------------------------
# T-nexus-7: ResolveNexusOperationStart{failed} fails the START await (no result
# job follows); it bubbles out as a FailWorkflowExecution.
# ---------------------------------------------------------------------------
T2->subtest('start failed fails the start await (T-nexus-7)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusCaller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'NexusCaller', arguments => [ payload('world') ],
        } } ],
    }));
    my @failed = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_nexus_operation_start => {
            seq => 1, failed => app_failure('StartFail', 'could not start'),
        } } ],
    }));
    T2->is(scalar @failed, 1, 'one command on a start failure');
    T2->is($failed[0]->which_variant, 'fail_workflow_execution',
        'a start failure bubbles out of :Run (no result job follows)');
    my $failure = $failed[0]->fail_workflow_execution->failure;
    T2->is($failure->which_failure_info, 'nexus_operation_execution_failure_info',
        'the start failure surfaces as a Nexus operation failure');
});

# ---------------------------------------------------------------------------
# T-nexus-8: $handle->cancel emits RequestCancelNexusOperation under the default
# (wait_cancellation_completed); an abandon-typed op emits NO cancel command; a
# pre-scheduled cancel raises Cancelled immediately.
# ---------------------------------------------------------------------------
T2->subtest('$handle->cancel emits RequestCancelNexusOperation (T-nexus-8)' => sub {
    # default wait_cancellation_completed: cancel emits the command.
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusCanceller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'NexusCanceller',
            arguments     => [ payload('wait_cancellation_completed') ],
        } } ],
    }));
    # async start so the body parks on the result, then the cancel signal lands.
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_nexus_operation_start => {
            seq => 1, operation_token => 'tok-1',
        } } ],
    }));
    my @after_signal = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { signal_workflow => { signal_name => 'cancel' } } ],
    }));
    my ($cancel_cmd) = grep {
        $_->which_variant eq 'request_cancel_nexus_operation'
    } @after_signal;
    T2->ok(defined $cancel_cmd,
        'wait_cancellation_completed emits RequestCancelNexusOperation');
    T2->is($cancel_cmd->request_cancel_nexus_operation->seq, 1,
        'the cancel targets the nexus operation seq');
});

T2->subtest('abandon emits no cancel command (T-nexus-8)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusCanceller');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'NexusCanceller', arguments => [ payload('abandon') ],
        } } ],
    }));
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_nexus_operation_start => {
            seq => 1, operation_token => 'tok-1',
        } } ],
    }));
    my @after_signal = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { signal_workflow => { signal_name => 'cancel' } } ],
    }));
    my @cancel_cmds = grep {
        $_->which_variant eq 'request_cancel_nexus_operation'
    } @after_signal;
    T2->is(scalar @cancel_cmds, 0,
        'an abandon-typed nexus operation emits no cancel command');
    # abandon stops waiting immediately: the body resumes and the run completes
    # (the await raises Cancelled, which bubbles out as a cancel outcome).
    my ($outcome) = grep {
        $_->which_variant =~ /workflow_execution$/
    } @after_signal;
    T2->ok(defined $outcome, 'abandon resolves the body in this activation');
});

T2->subtest('pre-scheduled cancel raises Cancelled immediately (T-nexus-8)' => sub {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NexusPreCancelled');
    $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [ { initialize_workflow => {
            workflow_type => 'NexusPreCancelled',
        } } ],
    }));
    # CancelWorkflow unwinds the timer await; the body then schedules a nexus op
    # while cancel-requested, so the start await raises Cancelled immediately.
    my @after_cancel = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { cancel_workflow => {} } ],
    }));
    my ($complete) = grep {
        $_->which_variant eq 'complete_workflow_execution'
    } @after_cancel;
    T2->ok(defined $complete,
        'the body completes after the pre-scheduled cancel');
    T2->is($PC->from_payload($complete->complete_workflow_execution->result),
        'pre-cancelled',
        'start_operation raised Cancelled immediately under a pending cancel');
});

# ---------------------------------------------------------------------------
# T-nexus-9: a ResolveNexusOperation for an unknown seq is a non-determinism
# error. With nondeterminism_as_workflow_fail set it FAILS THE WORKFLOW.
# ---------------------------------------------------------------------------
T2->subtest('unknown-seq resolve -> non-determinism (T-nexus-9)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class                  => 'WfDef::NexusCaller',
        nondeterminism_as_workflow_fail => 1,
    );
    my @commands = $harness->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 100 },
        jobs   => [
            { initialize_workflow => {
                workflow_type => 'NexusCaller', arguments => [ payload('world') ],
            } },
            { resolve_nexus_operation => {
                seq => 99, result => { completed => payload('x') },
            } },
        ],
    }));
    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        'an unknown-seq nexus resolve is non-determinism (fails the workflow)');
    T2->like($commands[0]->fail_workflow_execution->failure->message,
        qr/99|non-?determin/i,
        'failure mentions the offending seq / non-determinism');
});

T2->done_testing;
