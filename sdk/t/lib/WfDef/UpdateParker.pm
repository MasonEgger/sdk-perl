# ABOUTME: Replay fixture (B3 / #8, t/replay/repro_cancel_mid_update.t): an
# ABOUTME: :Update handler that parks
# ABOUTME: mid-flight on a never-true wait_condition while :Run also parks. A
# ABOUTME: client cancel landing mid-update must surface a clean Cancelled
# ABOUTME: (CancelWorkflowExecution) rather than hanging the workflow task.
# ABOUTME: Also reused by spec I1 / GitHub #1
# ABOUTME: (t/replay/evict_pending_update_wait_condition.t): the same
# ABOUTME: wait_condition-parked `park` handler exercises eviction, and the
# ABOUTME: added `park_plain` handler (parked on a plain untracked Future, the
# ABOUTME: R17 shape) exercises the mixed-parking eviction case in the SAME run.
# ABOUTME: Spec F8 adds the `park_signal` :Signal arm and the %CANCELS ledger.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Workflow::Future ();

# Spec F8 resumption ledger, %WfDef::UpdateParker::CANCELS, keyed by handler
# name: how many times a parked handler frame RESUMED with a
# Temporalio::Exception::Cancelled. A package variable rather than a field
# because the test reads it after the dispatcher has dropped both the runner
# and the workflow instance. It is written below by fully qualified name (this
# file declares no `package`, so a file-scope `our` would land in main::). The
# test resets it before each run; a counter must never exceed 1 per parked
# handler, which is what pins evict()'s sweep order (a second resumption is
# the double-settle the I1 sweep reorder removed). Deterministic: it counts
# frame resumptions in sweep order and never consults a clock or hash order.

# The :Run parks on a never-true wait_condition so the workflow stays open. The
# `park` :Update handler is async: on the activation that delivers the DoUpdate
# it emits UpdateResponse.accepted, then parks on its OWN never-true
# wait_condition (so start_update(wait_for_stage => 'accepted') returns with the
# handler genuinely mid-flight). A client cancel arriving while the handler is
# parked must raise a throwable Temporalio::Exception::Cancelled into BOTH the
# :Run body and the in-flight handler's await: the body unwinds to
# CancelWorkflowExecution and the handler settles cleanly. Before the B3 fix the
# parked condition future native-cancelled, so the cancel hung the workflow task
# (~183s) instead of producing a clean Cancelled.
#
# `park_plain` (spec I1) parks on a plain Temporalio::Workflow::Future instead
# (the R17 / WfDef::PlainFutureUpdater shape): its handler future is NATIVELY
# cancellable by evict()'s sweep, unrelated to any @conditions entry, so a run
# holding BOTH `park` and `park_plain` in flight exercises the mixed-parking
# eviction case (I1 sub-step 4) in one class, per Directive 6 (one attributed
# class per file; multiple attributed methods in that one class are fine).
class WfDef::UpdateParker :isa(Temporalio::Workflow::Definition) {
    field $done = 0;

    async method run :Run('UpdateParker') () {
        await Temporalio::Workflow::wait_condition(sub { $done });
        return 'run-done';
    }

    async method park :Update('park') () {
        my $ok = eval {
            await Temporalio::Workflow::wait_condition(sub { 0 });
            1;
        };
        return 'update-done' if $ok;

        my $err = $@;
        $WfDef::UpdateParker::CANCELS{park}++
            if Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Cancelled');
        die $err;    ## no critic (ErrorHandling::RequireCarping)
    }

    async method park_plain :Update('park_plain') () {
        my $ok = eval {
            await Temporalio::Workflow::Future->new;
            1;
        };
        return 'update-plain-done' if $ok;

        my $err = $@;
        $WfDef::UpdateParker::CANCELS{park_plain}++
            if Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Cancelled');
        die $err;    ## no critic (ErrorHandling::RequireCarping)
    }

    # Spec F8: the :Signal twin of `park`. A signal has no response channel, so
    # its eviction settlement runs through _settle_signal rather than
    # _settle_update, and the two must behave identically under evict(): no
    # command, no activation error, no croak.
    async method park_signal :Signal('park_signal') () {
        my $ok = eval {
            await Temporalio::Workflow::wait_condition(sub { 0 });
            1;
        };
        return if $ok;

        my $err = $@;
        $WfDef::UpdateParker::CANCELS{park_signal}++
            if Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Cancelled');
        die $err;    ## no critic (ErrorHandling::RequireCarping)
    }
}

1;
