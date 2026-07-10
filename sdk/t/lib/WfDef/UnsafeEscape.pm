# ABOUTME: Fixture workflow that calls a trapped builtin (time) but wrapped in
# ABOUTME: Unsafe::illegal_call_tracing_disabled, so the guard is suppressed for
# ABOUTME: the block and the call returns the OS clock value (T-det-2/T-det-3).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Workflow::Unsafe;

# The :Run calls `time` twice. The first call is inside an
# illegal_call_tracing_disabled block (suppressed -> returns the OS clock, no
# throw). It then awaits a timer; after resuming it calls `time` again OUTSIDE
# any suppression -> must throw Nondeterminism, proving suppression is scoped to
# the block and does NOT leak across the await (T-det-3).
class WfDef::UnsafeEscape :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($leak = 0) {
        my $inside = Temporalio::Workflow::Unsafe::illegal_call_tracing_disabled(sub {
            return time;
        });
        # When $leak is true, prove the suppression did NOT persist: this bare
        # call must throw because we are back in guarded context.
        if ($leak) {
            await Temporalio::Workflow::sleep(1);
            my $after = time;    # must throw Nondeterminism
            return { inside => $inside, after => $after };
        }
        return { inside => $inside };
    }
}

1;
