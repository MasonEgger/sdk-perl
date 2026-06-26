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
    method execute_activity { $_[0]->get('_root')->($_[0]) }
}

1;
