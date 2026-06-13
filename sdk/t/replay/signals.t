# ABOUTME: Replay tests for SignalWorkflow handling in the Runner (spec section
# ABOUTME: 10.3): signal dispatch to :Signal handlers, before-:Run-returns
# ABOUTME: visibility (T-wf-3), in-order delivery, dynamic-handler fallback,
# ABOUTME: buffering of signals delivered before a handler exists, and async
# ABOUTME: signal-handler tracking (the handler's Future is pumped to completion).
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

no warnings 'experimental::class';

# Build a WorkflowActivation proto. The job list is the oneof-tagged hashref
# form the generated classes accept.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# ---------------------------------------------------------------------------
# T-wf-3: a SignalWorkflow job delivered in the SAME activation as
# InitializeWorkflow is processed before the :Run continuation observes its
# state. The body parks on a timer; the signal mutates a field; when the timer
# fires the completion carries the signalled value. Signals are ordered BEFORE
# the start job (de-facto spec / sdk-python job set (1) before (2)), but the
# handler runs against the instance that initialize creates, so the runner
# buffers the signal until the instance exists and drains it right after init.
# ---------------------------------------------------------------------------
T2->subtest('signal in the init activation is visible to :Run (T-wf-3)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::SignalGreeter',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'add',
                input       => [ payload('hi') ],
            } },
            { initialize_workflow => {
                workflow_type => 'SignalGreeter',
                arguments     => [],
            } },
        ],
    }));

    # The body parked on the timer: only StartTimer, no completion yet.
    T2->is(scalar @first, 1, 'only the StartTimer command on the init activation');
    T2->is($first[0]->which_variant, 'start_timer', 'the body parked on the timer');

    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 160 },
        jobs      => [
            { fire_timer => { seq => 1 } },
        ],
    }));

    T2->is(scalar @second, 1, 'one command after the timer fires');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'the workflow completes after the timer fires');
    T2->is($PC->from_payload($second[0]->complete_workflow_execution->result),
        'hi', 'the signal mutated state the :Run continuation read');
});

# ---------------------------------------------------------------------------
# Multiple signals are delivered IN ORDER (sdk-python appends to the handled
# set in arrival order). Two named signals across two activations accumulate in
# the field in the order they arrived.
# ---------------------------------------------------------------------------
T2->subtest('signals are delivered in arrival order' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::SignalGreeter',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'SignalGreeter',
                arguments     => [],
            } },
            { signal_workflow => {
                signal_name => 'add',
                input       => [ payload('a') ],
            } },
            { signal_workflow => {
                signal_name => 'setPrefix',
                input       => [ payload('P') ],
            } },
            { signal_workflow => {
                signal_name => 'add',
                input       => [ payload('b') ],
            } },
        ],
    }));

    my @done = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 160 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));

    T2->is($done[0]->which_variant, 'complete_workflow_execution',
        'workflow completes');
    # add('a'), then setPrefix('P') (unshifts prefix:P), then add('b'):
    #   ['a'] -> ['prefix:P','a'] -> ['prefix:P','a','b'].
    T2->is($PC->from_payload($done[0]->complete_workflow_execution->result),
        'prefix:P,a,b', 'signals applied in arrival order');
});

# ---------------------------------------------------------------------------
# An unmatched signal name routes to the dynamic catch-all handler, which
# receives (name, @args) (mirrors sdk-python dynamic signal (name, args)).
# ---------------------------------------------------------------------------
T2->subtest('unmatched signal routes to the dynamic handler' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DynamicSignalGreeter',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DynamicSignalGreeter',
                arguments     => [],
            } },
            { signal_workflow => {
                signal_name => 'whatever',
                input       => [ payload('x') ],
            } },
        ],
    }));

    my @done = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 160 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));

    T2->is($done[0]->which_variant, 'complete_workflow_execution',
        'workflow completes');
    T2->is($PC->from_payload($done[0]->complete_workflow_execution->result),
        'whatever=x', 'the dynamic handler received the signal name and args');
});

# ---------------------------------------------------------------------------
# QUEUEING: a signal whose name has NO handler (and no dynamic handler) is
# buffered. SignalGreeter has named handlers but not "ghost"; the buffered
# signal is held and never dispatched (no handler ever appears in this static
# model), so it does not affect the result and does NOT fail the workflow.
# ---------------------------------------------------------------------------
T2->subtest('signal with no handler is buffered, not an error' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::SignalGreeter',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'SignalGreeter',
                arguments     => [],
            } },
            { signal_workflow => {
                signal_name => 'ghost',
                input       => [ payload('boo') ],
            } },
            { signal_workflow => {
                signal_name => 'add',
                input       => [ payload('real') ],
            } },
        ],
    }));

    my @done = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 160 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));

    T2->is($done[0]->which_variant, 'complete_workflow_execution',
        'workflow completes (unhandled signal did not fail it)');
    T2->is($PC->from_payload($done[0]->complete_workflow_execution->result),
        'real', 'the handled signal applied; the unhandled one was buffered');

    # The buffered signal is still queued in the runner.
    my $buffered = $harness->runner->_buffered_signal_names;
    T2->is($buffered, ['ghost'], 'the unhandled signal remains buffered');
});

# ---------------------------------------------------------------------------
# ASYNC HANDLER TRACKING: an async :Signal handler that awaits its own timer is
# tracked in the runner's in-progress-handlers set and pumped like any other
# workflow Future. On the activation that delivers the signal, the handler parks
# on its timer (emitting a StartTimer) and the workflow is NOT complete. A later
# FireTimer for the handler's timer resumes the handler, which flips the run's
# guard; the run body then returns and the workflow completes.
# ---------------------------------------------------------------------------
T2->subtest('async signal handler is tracked and pumped to completion' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::AsyncSignalHandler',
    );

    # Init: the :Run body parks on its own timer (seq 1).
    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'AsyncSignalHandler',
                arguments     => [],
            } },
        ],
    }));
    T2->is(scalar @init, 1, 'init activation emits the run body timer only');
    T2->is($init[0]->which_variant, 'start_timer', 'run body parked on its timer');
    T2->is($init[0]->start_timer->seq, 1, 'run body timer is seq 1');

    # Deliver the signal: the async handler parks on ITS timer (seq 2). The
    # handler is in-progress, so NO completion is emitted even though the run
    # body's guard is still false.
    my @sig = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'go',
                input       => [ payload('resolved') ],
            } },
        ],
    }));
    my %variant;
    $variant{$_->which_variant}++ for @sig;
    T2->is($variant{start_timer}, 1, 'the async handler emitted its own StartTimer');
    T2->ok(!$variant{complete_workflow_execution},
        'workflow does NOT complete while the signal handler is in-flight');
    T2->ok(!$harness->runner->_all_handlers_finished,
        'the in-progress-handlers set tracks the outstanding handler');
    my ($handler_timer) = grep { $_->which_variant eq 'start_timer' } @sig;
    T2->is($handler_timer->start_timer->seq, 2, 'the handler timer is seq 2');

    # Fire the handler's timer: the handler resumes, flips the guard, finishes.
    my @after_handler = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [ { fire_timer => { seq => 2 } } ],
    }));
    T2->ok($harness->runner->_all_handlers_finished,
        'the handler finished after its timer fired');

    # The run body re-checks its guard on its next timer tick. Fire the run
    # body's first timer (seq 1) to re-enter the until-loop, which now sees the
    # guard true and returns.
    my @done;
    # The run body may have re-armed a new timer; drive timers until it completes.
    my $next_seq = 1;
    my $ts       = 115;
    for (1 .. 5) {
        @done = $harness->push_activation(activation({
            run_id    => 'r1',
            timestamp => { seconds => $ts },
            jobs      => [ { fire_timer => { seq => $next_seq } } ],
        }));
        $ts += 5;
        last if grep { $_->which_variant eq 'complete_workflow_execution' } @done;
        # The run body re-armed the next timer; advance to it.
        my ($st) = grep { $_->which_variant eq 'start_timer' } @done;
        $next_seq = $st->start_timer->seq if $st;
    }

    my ($complete) =
        grep { $_->which_variant eq 'complete_workflow_execution' } @done;
    T2->ok($complete, 'the workflow completes once the handler-set guard is true');
    T2->is($PC->from_payload($complete->complete_workflow_execution->result),
        'resolved', 'the run returns the value the async handler set');
});

T2->done_testing;
