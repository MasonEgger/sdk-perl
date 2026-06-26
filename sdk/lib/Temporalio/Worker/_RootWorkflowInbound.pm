# ABOUTME: Root of the worker workflow-inbound interceptor chain (spec section
# ABOUTME: 27.2): runs the real run/signal/query/update via input's _root cb.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Worker::Interceptor ();

# The chain root the workflow-inbound interceptor list wraps (first-listed
# outermost). Each method performs the real dispatch by calling the private
# `_root` coderef the Runner stashed on the input — the same convention the
# client outbound chain uses (Temporalio::Client::_RootOutbound). The Runner
# builds this once per run and routes execute_workflow / handle_signal /
# handle_query / handle_update through the chain to here.
#
# Its own file because a `field :param = <default>` + a signatured method
# poisons the perl 5.38 `feature 'class'` parser once Future::AsyncAwait is
# loaded process-wide, and only one `class :isa` parses cleanly per file under
# F::AA. Methods are signature-less for the same reason.
class Temporalio::Worker::_RootWorkflowInbound
    :isa(Temporalio::Worker::WorkflowInbound) {
    method execute_workflow { $_[0]->get('_root')->($_[0]) }
    method handle_signal    { $_[0]->get('_root')->($_[0]) }
    method handle_query     { $_[0]->get('_root')->($_[0]) }
    method handle_update    { $_[0]->get('_root')->($_[0]) }
}

1;
