# ABOUTME: Fixture workflow whose :Run awaits wait_condition with a timeout that
# ABOUTME: is never satisfied — drives the timeout path in wait_condition.t
# ABOUTME: (T-wf-5 timeout variant): the condition timer fires and raises Timeout.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Timeout ();

# The :Run waits on a predicate that is ALWAYS false, with a timeout. The
# predicate never becomes true, so the timeout timer fires; wait_condition then
# raises a Temporalio::Exception::Timeout at the await site (MUST-match
# sdk-python asyncio.wait_for raising TimeoutError when the inner future does
# not resolve before the timeout). The body catches it and returns a marker so
# the test can assert the timeout raised the right exception class.
class WfDef::ConditionTimeouter :isa(Temporalio::Workflow::Definition) {
    field $never = 0;

    async method run :Run () {
        my $outcome = eval {
            await Temporalio::Workflow::wait_condition(
                sub { $never }, timeout => 30);
            'returned';
        };
        if (my $err = $@) {
            return 'timed-out'
                if Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::Timeout');
            die $err;
        }
        return $outcome;
    }
}

1;
