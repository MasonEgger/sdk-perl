# ABOUTME: Root of the client outbound interceptor chain (spec section 27.2):
# ABOUTME: performs the real RPC by delegating to the client's _root_* methods.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Client::Interceptor ();

# The chain root the interceptor list wraps (first-listed outermost). Its
# methods perform the real RPC by delegating to the owning client's private
# _root_* implementations. signal/query/update are issued from a WorkflowHandle,
# which stashes the real RPC body as the input's private `_root` coderef.
#
# This class lives in its own file because a `field :param = <default>` + a
# signatured method (as in Temporalio::Client) poisons the perl 5.38
# `feature 'class'` parser for any subsequent class in the same compilation
# unit once Future::AsyncAwait is loaded process-wide. Methods here are also
# signature-less for the same reason (see Temporalio::Client::Interceptor).
class Temporalio::Client::_RootOutbound
    :isa(Temporalio::Client::OutboundInterceptor) {
    field $client :param;

    method start_workflow { $client->_root_start_workflow($_[0]) }
    method signal_with_start_workflow {
        $client->_root_signal_with_start_workflow($_[0]);
    }
    method signal_workflow       { $_[0]->get('_root')->($_[0]) }
    method query_workflow        { $_[0]->get('_root')->($_[0]) }
    method start_workflow_update { $_[0]->get('_root')->($_[0]) }
}

1;
