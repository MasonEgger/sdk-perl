# ABOUTME: Fixture workflow whose :Signal handlers raise one value from each
# ABOUTME: branch of the Runner's shared failure classifier (spec F2, GitHub
# ABOUTME: issue #2): a Cancelled delivered by the whole-workflow cancel sweep,
# ABOUTME: a continue-as-new control signal, a Nondeterminism, a Temporal
# ABOUTME: Application failure, a workflow_failure_exception_types class, and a
# ABOUTME: plain die raised during eviction teardown. Drives
# ABOUTME: t/replay/signal_handler_classification.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();
use Temporalio::Exception::Nondeterminism ();
use WfDef::CustomError ();

# The :Run parks forever on a never-true wait_condition, so every command in
# the completion under test comes from a signal handler, not the body. Each
# handler raises exactly one classifier input (spec F2 / Runner
# _classify_failure); a test picks the handler for the branch it is asserting.
# Several handlers are async so their Future is still pending when
# _dispatch_signal returns and is tracked in %in_progress_handlers: that is the
# arm the cancel sweep and evict() reach, and the arm the I2 regression broke.
#
# Directive 6 allows several attributed methods in one attributed class; only
# the `class :isa(...)` declaration is one-per-file.
class WfDef::SignalClassifier :isa(Temporalio::Workflow::Definition) {
    field $never = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $never });
        return 'unreachable';
    }

    # Parks on its own timer. The whole-workflow cancel sweep and evict() both
    # cancel that timer, which fails it Temporalio::Exception::Cancelled; the
    # Cancelled propagates out of the await and fails this handler's return
    # Future. That failed-with-Cancelled future (NOT a natively cancelled one)
    # is what the classifier must route to the cancel branch.
    async method park :Signal('park') () {
        await Temporalio::Workflow::sleep(1);
        return 'unreachable';
    }

    # Same park, but the handler swallows the teardown Cancelled and dies with
    # a plain string instead. That plain die is the one value the pre-F2
    # settlement recorded in $current_activation_error during evict(), which
    # the eviction drop rule forbids.
    async method park_catch :Signal('park_catch') () {
        eval { await Temporalio::Workflow::sleep(1); 1 } or do {
            die "teardown boom in evicting signal\n";
        };
        return 'unreachable';
    }

    # continue_as_new dies with the Temporalio::Workflow::ContinueAsNew control
    # object, which is deliberately NOT a Temporalio::Exception. It must become
    # a ContinueAsNewWorkflowExecution command, never a task failure.
    method again :Signal('again') () {
        Temporalio::Workflow::continue_as_new(
            'NextRun',
            args => [ 'from-signal' ],
        );
        return;
    }

    # A Nondeterminism isa Temporalio::Exception, so the generic
    # Temporal-failure branch would fail the EXECUTION. It must be classified
    # ahead of that branch and fail the TASK instead, exactly as when it
    # escapes :Run.
    method bad :Signal('bad') () {
        Temporalio::Exception::Nondeterminism->throw(
            message => 'nondeterminism from signal handler',
        );
        return;
    }

    # A non-Temporal class that fails the EXECUTION only when the worker lists
    # it in workflow_failure_exception_types.
    method custom :Signal('custom') () {
        WfDef::CustomError->throw(message => 'custom boom from signal handler');
        return;
    }

    # The async arm of the Temporal-failure branch: the handler parks first, so
    # its failure arrives on a LATER activation through the tracked
    # %in_progress_handlers path.
    async method app_async :Signal('app_async') () {
        await Temporalio::Workflow::sleep(1);
        Temporalio::Exception::Application->throw(
            message => 'app boom from async signal handler',
            type    => 'AsyncBoomError',
        );
        return;
    }
}

1;
