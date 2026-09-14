# ABOUTME: Regression repro for spec I1 / GitHub #1: evicting a run holding a
# ABOUTME: pending async :Update PARKED ON wait_condition croaked, so the
# ABOUTME: RemoveFromCache completion was never sent. Handler-future sibling
# ABOUTME: of R17 (finding L7, commit f728d59's post-cancel cluster). Spec F8
# ABOUTME: extends it: settlement must be SILENT under evict (no UpdateResponse,
# ABOUTME: no failure converter run), for :Signal as well as :Update.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;
use Scalar::Util ();

use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Worker::WorkflowDispatcher ();
use TestFailureConverter::Dying ();
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
        data_converter => $args{data_converter}
            // Temporalio::Converter::Data->new,
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
    %WfDef::UpdateParker::CANCELS = ();
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

    # Spec F8: the sweep resumed the parked frame EXACTLY once. This is the
    # non-tautological half of the I1 pin: the fixed empty-success completion
    # above is sent by _handle_eviction no matter what evict() did internally,
    # so only the in-workflow ledger can tell a single settle from the pre-fix
    # double settle.
    T2->is($WfDef::UpdateParker::CANCELS{park}, 1,
        'the condition-parked update handler resumed with Cancelled exactly '
      . 'once (@conditions is swept before %in_progress_handlers, so the '
      . 'tracked clone is already ready when the handler pass reaches it)');
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
    %WfDef::UpdateParker::CANCELS = ();
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
    T2->is(scalar(@$completions), 3, 'the eviction completion was sent');
    my $c1 = $Completion->decode($completions->[-1]);
    T2->ok(defined $c1->successful, 'eviction completion is the empty success');
    T2->is(scalar(($c1->successful->commands // [])->@*), 0,
        'eviction completion carries no commands');

    # Spec F8, the two settlement arms, told apart by the ledger rather than by
    # the (always identical) eviction completion:
    #   condition park -> the sweep FAILS the real _ConditionFuture, so the
    #     frame RESUMES with Cancelled: exactly one resumption.
    #   plain-future park (R17) -> the handler future is natively cancelled, so
    #     Future::AsyncAwait discards the frame without unwinding it: the eval
    #     inside the handler never runs, hence zero resumptions.
    T2->is($WfDef::UpdateParker::CANCELS{park}, 1,
        'the condition-parked update handler resumed with Cancelled exactly '
      . 'once');
    T2->is($WfDef::UpdateParker::CANCELS{park_plain}, undef,
        'the plain-future-parked update handler was natively cancelled, so '
      . 'its frame was discarded rather than resumed');
});

# ---------------------------------------------------------------------------
# Spec F8: a wait_condition-parked async :Signal handler is the SAME eviction
# shape as `park` above, but it settles through _settle_signal instead of
# _settle_update. A signal has no response channel, so the only way it could
# speak during eviction is by claiming the one-shot terminal command slot or by
# recording a workflow task failure; F2's $evicting guard already stops both.
# This subtest pins that claim, which the I1 review flagged as asserted but
# untested. Python parity: _apply_remove_from_cache cancels EVERY outstanding
# task without discriminating on what produced it
# (../sdk-python temporalio/worker/_workflow_instance.py:797-808), and anything
# those cancels raise is swallowed under self._deleting (:484-490).
# ---------------------------------------------------------------------------
T2->subtest(
    'evict with a wait_condition-parked async :Signal handler settles '
  . 'silently (F8)' => sub
{
    %WfDef::UpdateParker::CANCELS = ();
    my ($dispatcher, $completions) =
        build_dispatcher(workflows => ['WfDef::UpdateParker']);

    await_f($dispatcher->dispatch_task(
        activation_bytes('r3', [
            { initialize_workflow => { workflow_type => 'UpdateParker' } },
        ])));

    await_f($dispatcher->dispatch_task(
        activation_bytes('r3', [
            { signal_workflow => { signal_name => 'park_signal', input => [] } },
        ], seconds => 101)));

    # Setup sanity: the signal activation emitted nothing (the handler parked
    # rather than returning), so the run is still open with the handler tracked
    # in %in_progress_handlers.
    my $c0 = $Completion->decode($completions->[-1]);
    T2->ok(defined $c0->successful,
        'the signal activation completed successfully');
    T2->is(scalar(($c0->successful->commands // [])->@*), 0,
        'the parked signal handler emitted no commands');

    my $err = T2->dies(sub {
        await_f($dispatcher->dispatch_task(
            activation_bytes('r3',
                [ { remove_from_cache => { message => 'cache full' } } ],
                seconds => 102)));
    });
    T2->is($err, undef,
        'evict survives the wait_condition-parked in-flight signal handler');

    T2->ok(!$dispatcher->has_runner('r3'), 'runner dropped after eviction');
    T2->is(scalar(@$completions), 3, 'the eviction completion was sent');
    my $c1 = $Completion->decode($completions->[-1]);
    T2->ok(defined $c1->successful, 'eviction completion is the empty success');
    T2->is(scalar(($c1->successful->commands // [])->@*), 0,
        'eviction completion carries no commands: no FailWorkflowExecution '
      . 'and no CancelWorkflowExecution from the resumed signal handler');
    T2->is($WfDef::UpdateParker::CANCELS{park_signal}, 1,
        'the condition-parked signal handler resumed with Cancelled exactly '
      . 'once');
});

# ---------------------------------------------------------------------------
# Spec F8, the teardown-integrity half: nothing a handler settlement runs
# during evict() may ESCAPE evict(). Pre-fix, a condition-parked update resumed
# with a FAILED (not natively cancelled) future, so _update_settlement took its
# `rejected` arm, ran the failure converter and pushed an UpdateResponse onto
# @commands on a runner being torn down. Externally the command was harmless
# (WorkflowDispatcher::_handle_eviction deletes the runner before calling evict
# and sends its own fixed empty completion), but the converter CALL was not: a
# converter that dies takes evict() with it and the RemoveFromCache completion
# is never sent, which is exactly the failure mode the I1 sweep reorder fixed
# by a different route.
#
# Python has two layers here, and both mean "no response, no escape":
# _add_command raises _WorkflowBeingEvictedError while self._deleting
# (_workflow_instance.py:2076-2078 with :2093-2095), so run_update cannot reach
# its to_failure call at all, and run_update's outer `except BaseException:
# if self._deleting: return` (:710-717) swallows anything that still gets out.
# ---------------------------------------------------------------------------
T2->subtest(
    'a failure converter that dies does not escape evict() (F8)' => sub
{
    %WfDef::UpdateParker::CANCELS = ();
    my ($dispatcher, $completions) = build_dispatcher(
        workflows      => ['WfDef::UpdateParker'],
        data_converter => Temporalio::Converter::Data->new(
            failure_converter => TestFailureConverter::Dying->new),
    );

    await_f($dispatcher->dispatch_task(
        activation_bytes('r4', [
            { initialize_workflow => { workflow_type => 'UpdateParker' } },
        ])));

    await_f($dispatcher->dispatch_task(
        activation_bytes('r4', [
            { do_update => {
                id                   => 'u-4',
                protocol_instance_id => 'pi-4',
                name                 => 'park',
                input                => [],
                run_validator        => 1,
            } },
        ], seconds => 101)));

    my $c0 = $Completion->decode($completions->[-1]);
    my @ur = grep { $_->which_variant eq 'update_response' }
        ($c0->successful->commands // [])->@*;
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the update was accepted before the converter was armed');

    # Armed ONLY across the eviction activation: the accept path above and the
    # dispatcher's own failed-completion builder must keep working. $CALLS is
    # zeroed alongside the arming so it counts the eviction activation alone.
    my $err = T2->dies(sub {
        $TestFailureConverter::Dying::ARMED = 1;
        $TestFailureConverter::Dying::CALLS = 0;
        await_f($dispatcher->dispatch_task(
            activation_bytes('r4',
                [ { remove_from_cache => { message => 'cache full' } } ],
                seconds => 102)));
    });
    $TestFailureConverter::Dying::ARMED = 0;

    # Two assertions, because the first alone does not pin the claim: an
    # implementation that still CALLED the converter but swallowed the die in
    # an eval would keep $err undef. The count is what says the settlement
    # never ran at all (spec F8's `return if $evicting`, ahead of
    # _update_settlement's rejected arm).
    T2->is($err, undef,
        'a failure converter that dies cannot abort the teardown');
    T2->is($TestFailureConverter::Dying::CALLS, 0,
        'evict() made NO failure-converter call: the settlement never reached '
      . 'the rejected arm');
    T2->ok(!$dispatcher->has_runner('r4'), 'runner dropped after eviction');
    T2->is(scalar(@$completions), 3, 'the eviction completion was sent');
    my $c1 = $Completion->decode($completions->[-1]);
    T2->ok(defined $c1->successful, 'eviction completion is the empty success');
    T2->is($WfDef::UpdateParker::CANCELS{park}, 1,
        'the handler still resumed exactly once; only its settlement was '
      . 'suppressed');
});

# ---------------------------------------------------------------------------
# Spec F8: eviction must actually FREE the runner. The settlement closures the
# update path installs (`$settle` closes over $self, and on_ready closes over
# $settle) are the obvious cycle risk, so weaken a reference to the live runner
# and assert it is gone once the eviction activation returns. The run parks an
# :Update AND a :Signal on wait_condition, so the assertion covers the closure
# F8 touched on each settlement path rather than only the update one. Python's
# equivalent is deleting the run from _running_workflows after cancelling every
# task (_apply_remove_from_cache, ../sdk-python
# temporalio/worker/_workflow_instance.py:797-808); ours is refcounting, so the
# check has to be a weak reference rather than a container lookup.
# ---------------------------------------------------------------------------
T2->subtest('the runner is freed by eviction, with no reference cycle (F8)'
    => sub
{
    %WfDef::UpdateParker::CANCELS = ();
    my ($dispatcher, $completions) =
        build_dispatcher(workflows => ['WfDef::UpdateParker']);

    await_f($dispatcher->dispatch_task(
        activation_bytes('r5', [
            { initialize_workflow => { workflow_type => 'UpdateParker' } },
        ])));

    # BOTH condition-park sinks in the one run, because F8 changed a
    # settlement on each: `park` goes through _settle_update's early return and
    # `park_signal` through _settle_signal, and each installs its own
    # settlement closure over $self. One run covers both holders.
    #
    # `park_plain` (the R17 plain-future park) is deliberately NOT in this run.
    # Adding it turns the assertion below red, and the leak is PRE-EXISTING,
    # not F8's: the same three-shape run fails identically on HEAD (4aaabc7,
    # F7). What fails on that one shape is eviction itself. Probed with a
    # weakened runner reference: after RemoveFromCache the runner is FREED for
    # a condition-parked update, for a condition-parked signal, and for a run
    # with no handler parked at all, and is RETAINED only for the plain-future
    # park. (Without any eviction every shape retains its runner, the
    # handler-free one included, so merely dropping the dispatcher isolates
    # nothing.) On the retaining shape the awaited plain future is released
    # once nothing else holds it, reading is_cancelled true while held, and
    # evict's unconditional `%in_progress_handlers = ()` drops the tracked
    # handler future; what survives is the runner at refcount 1 plus the
    # workflow instance. The $settle/on_ready pair is NOT the holder: `park`
    # installs the same pair through _settle_update and is freed. The candidate
    # is the suspended handler frame, which Future::AsyncAwait discards on the
    # native cancel instead of resuming (after eviction the %CANCELS ledger
    # reads 1 for `park` and 0 for `park_plain`), leaving it holding its
    # lexicals: $self there is the WfDef::UpdateParker instance, one of the
    # two survivors named above. Which reference keeps the runner itself
    # alive is not yet identified. Out of scope for F8, which is about
    # settling SILENTLY; tracked as a follow-up alongside F8's "tasks
    # remain" tripwire.
    await_f($dispatcher->dispatch_task(
        activation_bytes('r5', [
            { do_update => {
                id                   => 'u-5-cond',
                protocol_instance_id => 'pi-5-cond',
                name                 => 'park',
                input                => [],
                run_validator        => 1,
            } },
            { signal_workflow => { signal_name => 'park_signal', input => [] } },
        ], seconds => 101)));

    # Setup sanity: the update was accepted (so its handler is genuinely
    # mid-flight) and the signal handler parked without emitting anything.
    my $c0 = $Completion->decode($completions->[-1]);
    my @ur = grep { $_->which_variant eq 'update_response' }
        ($c0->successful->commands // [])->@*;
    T2->is(scalar @ur, 1,
        'the update was accepted; both handlers are parked on wait_condition');

    my $weak_runner = $dispatcher->runner('r5');
    Scalar::Util::weaken($weak_runner);
    T2->ok(defined $weak_runner, 'the runner is alive while the run is cached');

    await_f($dispatcher->dispatch_task(
        activation_bytes('r5',
            [ { remove_from_cache => { message => 'cache full' } } ],
            seconds => 102)));

    T2->ok(!$dispatcher->has_runner('r5'), 'runner dropped after eviction');
    T2->is($weak_runner, undef,
        'the runner was FREED by eviction: no settlement closure, tracked '
      . 'handler future or condition entry from either the parked update or '
      . 'the parked signal still holds it');
    T2->is($WfDef::UpdateParker::CANCELS{park}, 1,
        'the parked update handler did resume, so the freed-runner check is '
      . 'not vacuous');
    T2->is($WfDef::UpdateParker::CANCELS{park_signal}, 1,
        'the parked signal handler did resume too');
});

T2->done_testing;
