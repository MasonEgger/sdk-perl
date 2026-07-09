# ABOUTME: Replay tests for init-activation signal ordering (spec R26, finding
# ABOUTME: R12): handlers for signals delivered in the initializing activation
# ABOUTME: run BEFORE the main routine's first statement (Python parity), in
# ABOUTME: cross-name arrival order; post-start signal delivery is unchanged.
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
# Python ordering, confirmed against ../sdk-python/temporalio/worker/
# _workflow_instance.py before encoding these assertions (spec R26 test note):
#   - activate() (:438-455) splits an activation's jobs into four ordered sets:
#     [0] notify_has_patch, [1] signal_workflow + do_update, [2] every other
#     non-query job INCLUDING initialize_workflow, [3] query_workflow.
#   - activate() (:461-471) applies each set and then pumps the event loop
#     (_run_once), so set-1 signal handler tasks run BEFORE set 2 applies
#     initialize_workflow and starts the main routine.
#   - _apply_signal_workflow (:1057-1065) dispatches immediately when the
#     handler is registered (class-decorated handlers always are; only a
#     missing handler buffers), so an init-activation signal handler runs at
#     least to its first await before the main routine's first statement.
# Signal-with-start therefore observes handler side effects in the main
# routine's prologue on Python; Perl must match (finding R12).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# R26: a signal delivered in the SAME activation as InitializeWorkflow runs
# its handler before the main routine's first statement. The fixture's :Run
# prologue snapshots the handler-mutated state as its FIRST statement and
# returns it synchronously, so the completion payload is exactly what the
# prologue saw.
# ---------------------------------------------------------------------------
T2->subtest('init-activation signal handler runs before the main prologue (R26)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::InitSignalProbe',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'note',
                input       => [ payload('hello') ],
            } },
            { initialize_workflow => {
                workflow_type => 'InitSignalProbe',
                arguments     => [],
            } },
        ],
    }));

    T2->is(scalar @cmds, 1, 'one command on the init activation');
    T2->is($cmds[0]->which_variant, 'complete_workflow_execution',
        'the synchronous body completed on the init activation');
    T2->is($PC->from_payload($cmds[0]->complete_workflow_execution->result),
        'note:hello',
        'the handler side effect was visible to the prologue first statement');
});

# ---------------------------------------------------------------------------
# R26 arrival order: multiple init-activation signals with DIFFERENT names run
# their handlers in activation arrival order, all before the main routine
# (Python applies set 1 in job order; a per-name buffer must not scramble the
# cross-name order).
# ---------------------------------------------------------------------------
T2->subtest('init-activation signals run in cross-name arrival order' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::InitSignalProbe',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'note',
                input       => [ payload('a') ],
            } },
            { signal_workflow => {
                signal_name => 'mark',
                input       => [ payload('b') ],
            } },
            { signal_workflow => {
                signal_name => 'note',
                input       => [ payload('c') ],
            } },
            { initialize_workflow => {
                workflow_type => 'InitSignalProbe',
                arguments     => [],
            } },
        ],
    }));

    T2->is($cmds[0]->which_variant, 'complete_workflow_execution',
        'the synchronous body completed on the init activation');
    T2->is($PC->from_payload($cmds[0]->complete_workflow_execution->result),
        'note:a,mark:b,note:c',
        'all three handlers ran before the prologue, in arrival order');
});

# ---------------------------------------------------------------------------
# Regression (R26 verify): a signal delivered AFTER the workflow started still
# dispatches to its handler on the later activation (the pre-R26 path).
# ---------------------------------------------------------------------------
T2->subtest('post-start signal delivery is unchanged' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::SignalGreeter',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'SignalGreeter',
                arguments     => [],
            } },
        ],
    }));
    T2->is($init[0]->which_variant, 'start_timer', 'the body parked on its timer');

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 130 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'add',
                input       => [ payload('later') ],
            } },
        ],
    }));

    my @done = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 160 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));

    T2->is($done[0]->which_variant, 'complete_workflow_execution',
        'the workflow completes after the timer fires');
    T2->is($PC->from_payload($done[0]->complete_workflow_execution->result),
        'later', 'the post-start signal mutated state the body read');
});

T2->done_testing;
