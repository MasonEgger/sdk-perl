# ABOUTME: Regression repro for spec I1 / GitHub #1: evicting a run holding a
# ABOUTME: pending async :Update PARKED ON wait_condition croaked, so the
# ABOUTME: RemoveFromCache completion was never sent. Handler-future sibling
# ABOUTME: of R17 (finding L7, commit f728d59's post-cancel cluster).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;

use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Worker::WorkflowDispatcher ();
use WfDef::UpdateParker ();

# ---------------------------------------------------------------------------
# The defect (spec I1, closes GitHub #1): R17 fixed a NATIVELY cancelled
# handler future (a plain-Future park, WfDef::PlainFutureUpdater). THIS
# defect is a different mechanism on the SAME evict() sweep, for a handler
# parked on wait_condition instead:
#
#   - wait_condition's awaitable is a _ConditionFuture (Runner.pm ~:1981)
#     whose ->cancel override is `->fail(Cancelled)`, not a native cancel
#     (Runner.pm ~:4528).
#   - Future::AsyncAwait builds the async :Update method's RETURN future by
#     AWAIT_CLONE of the FIRST future the body awaits (here, that very
#     _ConditionFuture), so the tracked handler future in
#     %in_progress_handlers takes the _ConditionFuture CLASS too (the same
#     mechanism documented for the main run future in
#     .ai-sessions/lessons.md's R8-R10 entry and
#     .ai-sessions/session-20260708-1748-goal-step-21-settle-cancelled-
#     updates.md's "Observations").
#   - Pre-fix, evict()'s combined @pending_futures list swept
#     %in_progress_handlers BEFORE @conditions (Runner.pm ~:2196-2204). The
#     WHICH-SWEEP-DOUBLE-SETTLES answer: the handler-future pass hits the
#     tracked clone first and ->cancel's it: the _ConditionFuture override
#     fires and ->fail(Cancelled)'s the clone (settle #1). The SAME evict()
#     call's later @conditions pass then ->cancel's the REAL underlying
#     _ConditionFuture (a DIFFERENT object, still pending; cloning does not
#     alias the original), which resumes the suspended async body
#     synchronously; the body's await raises the propagated Cancelled, and
#     Future::AsyncAwait tries to ->fail the method's return future, but the
#     SAME clone already failed in settle #1, so it croaks "... is already
#     failed and cannot be ->fail'ed" (settle #2). evict() dies before the
#     dispatcher ever sends the RemoveFromCache completion.
#
# Fixed by sweeping @conditions BEFORE %in_progress_handlers in evict()
# (Runner.pm evict()): failing the REAL condition future first resumes the
# body and lets Future::AsyncAwait settle the clone AS PART OF THAT SAME
# CANCEL, so the later handler-future pass finds the clone already
# ->is_ready and skips it (the loop's existing `unless $future->is_ready`
# guard): exactly one settle reaches the method future, the same
# sweep-then-guard discrimination _apply_cancel_workflow already uses for
# the main run future's cancel fallback (R8-R10). A plain-future-parked
# handler (R17) has no @conditions entry at all, so it is unaffected and
# still natively cancelled by the handler-future pass.
#
# Python ground truth: eviction's teardown exception is swallowed with NO
# response regardless of which awaitable a handler task was parked on
# (../sdk-python temporalio/worker/_workflow_instance.py
# _handle_cache_eviction: every outstanding task is cancelled and the run is
# deleted from _running_workflows before any response could be produced).
# ---------------------------------------------------------------------------

my $Activation = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_activation.WorkflowActivation');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_completion.WorkflowActivationCompletion');

# Activations resolve synchronously here (the Runner drives workflow Futures
# imperatively, no IO::Async), so ->get pumps them to completion.
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

T2->subtest(
    'evict with a wait_condition-parked async update completes without '
  . 'croaking (I1 / #1)' => sub
{
    my ($dispatcher, $completions) =
        build_dispatcher(workflows => ['WfDef::UpdateParker']);

    await_f($dispatcher->dispatch_task(
        activation_bytes('r1', [
            { initialize_workflow => { workflow_type => 'UpdateParker' } },
        ])));

    await_f($dispatcher->dispatch_task(
        activation_bytes('r1', [
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-1',
                name                 => 'park',
                input                => [],
                run_validator        => 1,
            } },
        ], seconds => 101)));

    # Setup sanity: the update was ACCEPTED but not completed; the handler
    # is parked on its own wait_condition, which is what makes evict()'s
    # sweep reach its tracked (AWAIT_CLONEd) future.
    my $c0 = $Completion->decode($completions->[-1]);
    my @ur = grep { $_->which_variant eq 'update_response' }
        ($c0->successful->commands // [])->@*;
    T2->is(scalar @ur, 1, 'exactly one UpdateResponse in the do_update activation');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the update was accepted; the handler is parked on wait_condition');

    # The crux: the eviction activation. Under the bug, evict() double-fails
    # the AWAIT_CLONEd handler future and dies before any completion is sent.
    my $err = T2->dies(sub {
        await_f($dispatcher->dispatch_task(
            activation_bytes('r1',
                [ { remove_from_cache => { message => 'cache full' } } ],
                seconds => 102)));
    });
    T2->is($err, undef,
        'evict survives the wait_condition-parked in-flight update handler '
      . '(no "already failed and cannot be ->fail\'ed" croak)');

    T2->ok(!$dispatcher->has_runner('r1'), 'runner dropped after eviction');
    T2->is(scalar(@$completions), 3, 'the eviction completion was sent');
    my $c1 = $Completion->decode($completions->[-1]);
    T2->ok(defined $c1->successful, 'eviction completion is the empty success');
    T2->is(scalar(($c1->successful->commands // [])->@*), 0,
        'eviction completion carries no commands (RemoveFromCache always '
      . 'sends the fixed empty-success completion regardless of any '
      . 'internal handler settlement)');
});

# ---------------------------------------------------------------------------
# I1 sub-step 4: mixed parking. A single run with BOTH a plain-future-parked
# update (the R17 arm, native cancel) AND a wait_condition-parked update
# (this step's arm, fail-via-clone-then-real-condition) in flight at the same
# time. Both arms must settle without either double-failing, and evict() must
# still produce exactly the one fixed eviction completion.
# ---------------------------------------------------------------------------
T2->subtest(
    'evict with BOTH a plain-future-parked and a wait_condition-parked '
  . 'update completes without croaking (I1 mixed case)' => sub
{
    my ($dispatcher, $completions) =
        build_dispatcher(workflows => ['WfDef::UpdateParker']);

    await_f($dispatcher->dispatch_task(
        activation_bytes('r2', [
            { initialize_workflow => { workflow_type => 'UpdateParker' } },
        ])));

    await_f($dispatcher->dispatch_task(
        activation_bytes('r2', [
            { do_update => {
                id                   => 'u-cond',
                protocol_instance_id => 'pi-cond',
                name                 => 'park',
                input                => [],
                run_validator        => 1,
            } },
            { do_update => {
                id                   => 'u-plain',
                protocol_instance_id => 'pi-plain',
                name                 => 'park_plain',
                input                => [],
                run_validator        => 1,
            } },
        ], seconds => 101)));

    my $c0 = $Completion->decode($completions->[-1]);
    my @ur = grep { $_->which_variant eq 'update_response' }
        ($c0->successful->commands // [])->@*;
    T2->is(scalar @ur, 2,
        'both updates were accepted; both handlers are parked mid-flight');

    my $err = T2->dies(sub {
        await_f($dispatcher->dispatch_task(
            activation_bytes('r2',
                [ { remove_from_cache => { message => 'cache full' } } ],
                seconds => 102)));
    });
    T2->is($err, undef,
        'evict survives BOTH the plain-future-parked and the '
      . 'wait_condition-parked in-flight update handlers, in the same run');

    T2->ok(!$dispatcher->has_runner('r2'), 'runner dropped after eviction');
    T2->is(scalar(@$completions), 3,
        'exactly one eviction completion was sent (not one per handler)');
    my $c1 = $Completion->decode($completions->[-1]);
    T2->ok(defined $c1->successful, 'eviction completion is the empty success');
    T2->is(scalar(($c1->successful->commands // [])->@*), 0,
        'eviction completion carries no commands');
});

T2->done_testing;
