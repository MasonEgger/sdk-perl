# ABOUTME: Replay fixture (B3 / #8, t/replay/repro_cancel_mid_update.t): an
# ABOUTME: :Update handler that parks
# ABOUTME: mid-flight on a never-true wait_condition while :Run also parks. A
# ABOUTME: client cancel landing mid-update must surface a clean Cancelled
# ABOUTME: (CancelWorkflowExecution) rather than hanging the workflow task.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

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
class WfDef::UpdateParker :isa(Temporalio::Workflow::Definition) {
    field $done = 0;

    async method run :Run('UpdateParker') () {
        await Temporalio::Workflow::wait_condition(sub { $done });
        return 'run-done';
    }

    async method park :Update('park') () {
        await Temporalio::Workflow::wait_condition(sub { 0 });
        return 'update-done';
    }
}

1;
