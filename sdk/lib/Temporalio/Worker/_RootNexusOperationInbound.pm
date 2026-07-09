# ABOUTME: Root of the Nexus operation inbound interceptor chain (spec R73):
# ABOUTME: runs the real start/cancel handler via the input's private _root cb.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Worker::Interceptor ();

# The chain root the nexus-operation-inbound interceptor list wraps
# (first-listed outermost, spec R73 parity finding 3). Both methods perform
# the real work by calling the private `_root` coderef the NexusDispatcher
# stashed on the input — the _RootActivityInbound convention. This is the Perl
# form of sdk-python's _NexusOperationInboundInterceptorImpl, whose start and
# cancel run the underlying operation handler (worker/_nexus.py:639-654,
# _interceptor.py:500-528). No init/outbound side: Python's nexus inbound has
# none either.
#
# Its own file because only one `class :isa` parses cleanly per lib file under
# Future::AsyncAwait on 5.38.2 (see lessons.md); methods are signature-less
# for the same parser reason.
class Temporalio::Worker::_RootNexusOperationInbound
    :isa(Temporalio::Worker::NexusOperationInbound) {
    method execute_nexus_operation_start  { $_[0]->get('_root')->($_[0]) }
    method execute_nexus_operation_cancel { $_[0]->get('_root')->($_[0]) }
}

1;
