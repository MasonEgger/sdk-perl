# ABOUTME: Root of the worker activity-inbound interceptor chain (spec section
# ABOUTME: 27.2): runs the real activity body via the input's private _root cb.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Worker::Interceptor ();

# The chain root the activity-inbound interceptor list wraps (first-listed
# outermost). Its execute_activity performs the real dispatch by calling the
# private `_root` coderef the ActivityDispatcher stashed on the input — the same
# convention the client outbound chain uses (Temporalio::Client::_RootOutbound).
#
# Its own file because a `field :param = <default>` + a signatured method
# poisons the perl 5.38 `feature 'class'` parser once Future::AsyncAwait is
# loaded process-wide, and only one `class :isa` parses cleanly per file under
# F::AA. Methods are signature-less for the same reason.
class Temporalio::Worker::_RootActivityInbound
    :isa(Temporalio::Worker::ActivityInbound) {
    # init capture (spec R72): the ActivityDispatcher calls init(root
    # outbound) on the inbound chain; each interceptor inbound may WRAP the
    # outbound before delegating down, so whatever arrives HERE is the
    # finished outbound chain. on_init hands it back to the dispatcher, the
    # Perl form of sdk-python's _ActivityInboundImpl.init installing
    # outbound.info/outbound.heartbeat on the context
    # (worker/_activity.py:813-818), mirroring _RootWorkflowInbound (R71).
    field $on_init :param = undef;
    method init { $on_init ? $on_init->($_[0]) : () }

    method execute_activity { $_[0]->get('_root')->($_[0]) }
}

1;
