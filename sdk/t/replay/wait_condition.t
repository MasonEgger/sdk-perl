# ABOUTME: Replay tests for workflow.wait_condition (spec section 10.2 / T-wf-5):
# ABOUTME: a predicate flipped by a signal resumes the awaiting :Run continuation
# ABOUTME: in the same activation (re-check per pump); a timeout fires a Timeout.
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

no warnings 'experimental::class';

# Build a WorkflowActivation proto with the given fields. The job list is the
# oneof-tagged hashref form the generated classes accept.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# ---------------------------------------------------------------------------
# T-wf-5: a workflow that awaits wait_condition parks on the InitializeWorkflow
# activation (the predicate is false) and emits NO completion. A later
# activation carrying the signal that flips the predicate resumes the awaiting
# :Run continuation in the SAME activation — the pump re-checks the predicate
# after applying the signal, sees it true, resolves the wait Future, and the
# body completes.
# ---------------------------------------------------------------------------
T2->subtest('wait_condition parks until a signal flips the predicate (T-wf-5)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ConditionWaiter',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ConditionWaiter',
                arguments     => [],
            } },
        ],
    }));

    T2->is(scalar @first, 0,
        'no command on init: the body parks on wait_condition');

    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'go',
                input       => [ payload('Alice') ],
            } },
        ],
    }));

    T2->is(scalar @second, 1, 'one command after the predicate flips true');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'the workflow completes once the condition is satisfied');
    T2->is(
        $PC->from_payload($second[0]->complete_workflow_execution->result),
        'ready:Alice',
        'the resumed :Run observed the signal-set state');
});

# ---------------------------------------------------------------------------
# Re-check per pump: the predicate stays pending across pumps until it becomes
# stably true. A counter-threshold predicate (count >= 2) is re-checked after
# every activation; one signal (count 1) leaves the wait pending (no
# completion), a second (count 2) satisfies it and resumes :Run.
# ---------------------------------------------------------------------------
T2->subtest('wait_condition is re-checked each pump until stable' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::CounterWaiter',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'CounterWaiter',
                arguments     => [],
            } },
        ],
    }));
    T2->is(scalar @init, 0, 'init parks: predicate false (count 0)');

    my @after_one = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [
            { signal_workflow => { signal_name => 'bump', input => [] } },
        ],
    }));
    T2->is(scalar @after_one, 0,
        'still parked after one bump: predicate still false (count 1)');

    my @after_two = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 120 },
        jobs      => [
            { signal_workflow => { signal_name => 'bump', input => [] } },
        ],
    }));
    T2->is(scalar @after_two, 1, 'completes once the counter reaches 2');
    T2->is($after_two[0]->which_variant, 'complete_workflow_execution',
        'the workflow completes when the predicate is stably true');
    T2->is(
        $PC->from_payload($after_two[0]->complete_workflow_execution->result),
        'count:2', 'the resumed :Run observed the post-second-bump count');
});

# ---------------------------------------------------------------------------
# Timeout variant (T-wf-5 timeout): wait_condition(timeout => N) starts a timer
# (StartTimer seq 1) and parks. When the timer's FireTimer arrives without the
# predicate ever becoming true, wait_condition raises a
# Temporalio::Exception::Timeout at the await site (MUST-match sdk-python
# asyncio.wait_for raising TimeoutError). The body catches it and completes.
# ---------------------------------------------------------------------------
T2->subtest('wait_condition timeout fires a Timeout when unsatisfied' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ConditionTimeouter',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ConditionTimeouter',
                arguments     => [],
            } },
        ],
    }));

    # The timeout is implemented as a StartTimer the wait races against; the
    # body parks, so exactly one StartTimer (seq 1, 30s) and no completion.
    T2->is(scalar @first, 1, 'one command on init: the timeout StartTimer');
    T2->is($first[0]->which_variant, 'start_timer',
        'wait_condition with a timeout emits a StartTimer');
    T2->is($first[0]->start_timer->seq, 1, 'timeout timer is seq 1');
    T2->is($first[0]->start_timer->start_to_fire_timeout->seconds, 30,
        'timeout timer is 30s');

    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 130 },
        jobs      => [
            { fire_timer => { seq => 1 } },
        ],
    }));

    T2->is(scalar @second, 1, 'one command after the timeout timer fires');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'the workflow completes after catching the timeout');
    T2->is(
        $PC->from_payload($second[0]->complete_workflow_execution->result),
        'timed-out',
        'the await site raised Temporalio::Exception::Timeout');
});

T2->done_testing;
