# ABOUTME: Fixture workflow for R13 (finding R9): answers a query or an update
# ABOUTME: and then fails the WORKFLOW in the same activation, so the failure
# ABOUTME: completion must carry the handler responses. One signal also starts
# ABOUTME: a timer first, proving state-mutating commands are still dropped.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

# The :Run parks on a wait_condition until a handler arms $fail, then throws an
# ApplicationError (a Temporal failure exception -> FailWorkflowExecution, not
# a task failure). Handlers:
#   fail-now         (:Signal)  arms the failure.
#   timer-then-fail  (:Signal)  buffers a StartTimer command FIRST (the future
#                               is deliberately discarded), then arms the
#                               failure — the timer command must NOT survive
#                               the failure completion.
#   status           (:Query)   answers; ordered LAST in the activation, so it
#                               responds after the body has already failed.
#   finish-and-fail  (:Update)  answers (accepted + completed) and arms the
#                               failure in the same activation.
class WfDef::FailingResponder :isa(Temporalio::Workflow::Definition) {
    field $fail = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $fail });
        Temporalio::Exception::Application->throw(
            message => 'intentional workflow failure',
            type    => 'IntentionalFailure',
        );
    }

    method fail_now :Signal('fail-now') () {
        $fail = 1;
        return;
    }

    method timer_then_fail :Signal('timer-then-fail') () {
        # Buffers the StartTimer command immediately (Runner start_timer pushes
        # the command at call time); the returned future is never awaited.
        Temporalio::Workflow::start_timer(3600);
        $fail = 1;
        return;
    }

    method status :Query('status') () {
        return 'answered';
    }

    method finish_and_fail :Update('finish-and-fail') (@) {
        $fail = 1;
        return 'update-answered';
    }
}

1;
