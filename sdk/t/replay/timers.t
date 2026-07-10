# ABOUTME: Replay tests for workflow-side timers (spec section 10.2 start_timer/
# ABOUTME: sleep + 10.3 FireTimer/CancelTimer): StartTimer emission (T-wf-6),
# ABOUTME: FireTimer resumption, the sleep alias, separate timer seq space, and
# ABOUTME: the CancelTimer-on-cancel path.
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
# T-wf-6: a workflow that sleeps emits exactly one StartTimer command on the
# first (InitializeWorkflow) activation, with seq=1 and a 60s start_to_fire
# timeout. The body parks on the timer Future, so NO completion is emitted yet.
# ---------------------------------------------------------------------------
T2->subtest('sleep emits StartTimer (T-wf-6)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TimerSleeper',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'TimerSleeper',
                arguments     => [ payload(60) ],
            } },
        ],
    }));

    T2->is(scalar @commands, 1, 'exactly one command emitted');
    my $cmd = $commands[0];
    T2->is($cmd->which_variant, 'start_timer', 'the command is StartTimer');

    my $st = $cmd->start_timer;
    T2->is($st->seq, 1, 'timer seq starts at 1');
    T2->is($st->start_to_fire_timeout->seconds, 60,
        'start_to_fire_timeout is 60s');
    T2->is($st->start_to_fire_timeout->nanos, 0,
        'start_to_fire_timeout has no fractional nanos');
});

# ---------------------------------------------------------------------------
# A second activation carrying FireTimer{seq:1} resumes the awaiting body; the
# workflow then completes (post-sleep commands appear — T-wf-6).
# ---------------------------------------------------------------------------
T2->subtest('FireTimer resumes the sleep and completes' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TimerSleeper',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'TimerSleeper',
                arguments     => [ payload(60) ],
            } },
        ],
    }));
    T2->is($first[0]->which_variant, 'start_timer',
        'first activation starts the timer');

    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 160 },
        jobs      => [
            { fire_timer => { seq => 1 } },
        ],
    }));

    T2->is(scalar @second, 1, 'one command after the timer fires');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'workflow completes after the timer fires');
    my $result = $second[0]->complete_workflow_execution->result;
    T2->is($PC->from_payload($result), 'slept',
        'completion carries the post-sleep return value');
});

# ---------------------------------------------------------------------------
# start_timer (without await) emits an identical StartTimer command and lets the
# body proceed without blocking. The sleep alias and start_timer produce the
# same StartTimer shape.
# ---------------------------------------------------------------------------
T2->subtest('start_timer emits StartTimer without blocking' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TimerStarter',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'TimerStarter',
                arguments     => [ payload(30) ],
            } },
        ],
    }));

    # The body returns without awaiting the timer: a StartTimer AND a
    # CompleteWorkflowExecution come back in the same activation.
    T2->is(scalar @commands, 2, 'StartTimer plus completion emitted');
    T2->is($commands[0]->which_variant, 'start_timer', 'first is StartTimer');
    T2->is($commands[0]->start_timer->seq, 1, 'timer seq 1');
    T2->is($commands[0]->start_timer->start_to_fire_timeout->seconds, 30,
        'start_to_fire_timeout is 30s');
    T2->is($commands[1]->which_variant, 'complete_workflow_execution',
        'second is the completion (body did not block on the timer)');
});

# ---------------------------------------------------------------------------
# Timers and activities allocate from SEPARATE seq spaces (MUST-match
# sdk-python _next_seq("timer") / _next_seq("activity"); sdk-ruby
# @timer_counter / @activity_counter). A workflow that sleeps gets timer seq 1
# even though a fresh runner's activity counter is also at 0.
# ---------------------------------------------------------------------------
T2->subtest('timers use a seq space separate from activities' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TimerSleeper',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'TimerSleeper',
                arguments     => [ payload(5) ],
            } },
        ],
    }));

    T2->is($commands[0]->start_timer->seq, 1,
        'the first timer is seq 1 in the timer seq space');
});

# ---------------------------------------------------------------------------
# Cancelling a timer Future emits a CancelTimer command (same seq) and resolves
# the Future as Temporalio::Exception::Cancelled (Workflow::Future on_cancel
# path; MUST-match sdk-ruby _apply_cancel_command / CanceledError).
# ---------------------------------------------------------------------------
T2->subtest('cancelling a timer emits CancelTimer and cancels the Future' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TimerCanceller',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'TimerCanceller',
                arguments     => [ payload(60) ],
            } },
        ],
    }));

    # StartTimer, then CancelTimer, then the completion (the body caught the
    # Cancelled exception and returned).
    my %variant;
    $variant{$_->which_variant}++ for @commands;
    T2->is($variant{start_timer}, 1, 'a StartTimer was emitted');
    T2->is($variant{cancel_timer}, 1, 'a CancelTimer was emitted');
    T2->is($variant{complete_workflow_execution}, 1,
        'the workflow completed after catching the cancellation');

    # The StartTimer and CancelTimer share the same seq.
    my ($start) = grep { $_->which_variant eq 'start_timer' } @commands;
    my ($cancel) = grep { $_->which_variant eq 'cancel_timer' } @commands;
    T2->is($cancel->cancel_timer->seq, $start->start_timer->seq,
        'CancelTimer references the StartTimer seq');

    # The body observed a Cancelled exception at the await site.
    my ($complete) = grep {
        $_->which_variant eq 'complete_workflow_execution'
    } @commands;
    T2->is($PC->from_payload($complete->complete_workflow_execution->result),
        'cancelled', 'the await site raised Temporalio::Exception::Cancelled');
});

T2->done_testing;
