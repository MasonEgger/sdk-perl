# ABOUTME: Regression repro for R16 (finding L6): evict() iterated the pending
# ABOUTME: tables ALIASED (values %pending_..., Workflow/Runner.pm:1532-1538), so
# ABOUTME: a cancel continuation that deletes a not-yet-visited SIBLING entry
# ABOUTME: (a Future->wait_any loser-cancel driving the on_cancel de-register)
# ABOUTME: frees a hash-slot alias the loop still holds. The evict croaks and the
# ABOUTME: eviction completion is never sent, wedging the run's cache slot.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
no warnings 'experimental::class';

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;

use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Worker::WorkflowDispatcher ();

# ---------------------------------------------------------------------------
# The defect (finding L6, spec R16; step-45 probes probe_l6_freed_iteration.pl
# and probe_l6_self_delete.pl):
#
#   evict() cancelled every pending future by iterating the flattened list
#       values %pending_activities, values %pending_timers, ...
#   (Workflow/Runner.pm:1532-1538). `values` in a foreach ALIASES the hash's
#   value slots. Future cancellation continuations run synchronously, and the
#   on_cancel hooks de-register their own pending entry (delete
#   $pending_activities{$seq} / $pending_timers{$seq}, the same de-registers the
#   whole-workflow-cancel sweeps snapshot `keys` around at :2199 and :2212).
#
#   Deleting the entry the loop is CURRENTLY visiting (self-delete) is
#   survivable — the step-45 self-delete probe showed that. The killer is a
#   SIBLING delete: cancelling the activity future fails it with Cancelled,
#   Future->wait_any sees a ready component and cancels the losing timer, whose
#   on_cancel deletes the NOT-YET-VISITED $pending_timers slot. The loop then
#   reaches a freed alias and croaks — "Use of freed value in iteration", or on
#   this perl (5.38.2) the freed slot reads back as undef and the loop croaks
#   "Can't call method \"is_ready\" on an undefined value" at Runner.pm:1537.
#   Either way evict() dies, the dispatcher's _handle_eviction never sends the
#   empty-success eviction completion, and core never sees the eviction ack.
#
# Fixed by iterating a copied snapshot of the pending values so continuations
# may delete any entry. These scenarios are deterministic replay (no server, no
# IO::Async timers): the dispatcher path mirrors workflow_poll_loop.t so the
# test can assert the eviction completion is actually SENT.
# ---------------------------------------------------------------------------

my $Activation = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_activation.WorkflowActivation');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_completion.WorkflowActivationCompletion');

# Activations resolve synchronously here (the Runner drives workflow Futures
# imperatively, no IO::Async), so ->get pumps them to completion. Matches
# workflow_poll_loop.t.
sub await_f ($f) { return $f->get }

sub activation_bytes ($run_id, $jobs, %opt) {
    return $Activation->new({
        run_id    => $run_id,
        timestamp => { seconds => $opt{seconds} // 100 },
        jobs      => $jobs,
    })->encode;
}

# Build a dispatcher over the given workflow classes; $completions collects the
# raw completion bytes handed to the injected completer.
sub build_dispatcher (%args) {
    my $registry = Temporalio::Worker::WorkflowRegistry->new(
        workflows => $args{workflows});
    my $completions = [];
    my $dispatcher  = Temporalio::Worker::WorkflowDispatcher->new(
        registry       => $registry,
        data_converter => Temporalio::Converter::Data->new,
        task_queue     => 'demo',
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
    );
    return ($dispatcher, $completions);
}

T2->subtest('evict whose cancel continuation deletes an unvisited sibling completes (R16 sibling delete)' => sub {
    # WfDef::WaitAnyRace parks on Future->wait_any(activity, timer): exactly the
    # shape whose evict-time cancel chain deletes the sibling timer entry.
    my ($dispatcher, $completions) =
        build_dispatcher(workflows => ['WfDef::WaitAnyRace']);

    await_f($dispatcher->dispatch_task(
        activation_bytes('r1',
            [ { initialize_workflow => { workflow_type => 'WaitAnyRace' } } ])));

    # Setup sanity: the body parked with BOTH pending tables populated (one
    # activity, one timer) — the two hash slots the evict loop flattens.
    my $c0 = $Completion->decode($completions->[0]);
    my %variants = map { $_->which_variant => 1 }
        ($c0->successful->commands // [])->@*;
    T2->ok($variants{schedule_activity}, 'init scheduled the racing activity');
    T2->ok($variants{start_timer},       'init armed the racing timer');

    # The crux: the eviction activation. Under the bug, cancelling the activity
    # future fails it Cancelled -> wait_any cancels the losing timer -> its
    # on_cancel deletes the unvisited $pending_timers slot -> the evict loop
    # hits the freed alias and croaks (no completion is ever sent).
    my $err = T2->dies(sub {
        await_f($dispatcher->dispatch_task(
            activation_bytes('r1',
                [ { remove_from_cache => { message => 'cache full' } } ])));
    });
    T2->is($err, undef, 'evict survives the sibling-entry delete (no freed-value croak)');

    T2->ok(!$dispatcher->has_runner('r1'), 'runner dropped after eviction');
    T2->is(scalar(@$completions), 2, 'the eviction completion was sent');
    my $c1 = $Completion->decode($completions->[-1]);
    T2->ok(defined $c1->successful, 'eviction completion is the empty success');
    T2->is(scalar(($c1->successful->commands // [])->@*), 0,
        'eviction completion carries no commands');
});

T2->subtest('evict deleting only its OWN entry stays survivable (R16 self delete)' => sub {
    # WfDef::ActivityCaller parks on a single pending activity: evict cancels
    # it and its on_cancel deletes the entry the loop is currently visiting.
    # The step-45 self-delete probe showed this is survivable; keep it pinned
    # so the snapshot fix doesn't regress the simple case.
    my ($dispatcher, $completions) =
        build_dispatcher(workflows => ['WfDef::ActivityCaller']);

    await_f($dispatcher->dispatch_task(
        activation_bytes('r2',
            [ { initialize_workflow => { workflow_type => 'ActivityCaller' } } ])));

    my $err = T2->dies(sub {
        await_f($dispatcher->dispatch_task(
            activation_bytes('r2',
                [ { remove_from_cache => { message => 'cache full' } } ])));
    });
    T2->is($err, undef, 'evict survives deleting its own currently-visited entry');

    T2->ok(!$dispatcher->has_runner('r2'), 'runner dropped after eviction');
    my $c = $Completion->decode($completions->[-1]);
    T2->ok(defined $c->successful, 'eviction completion is the empty success');
});

T2->done_testing;
