# ABOUTME: Root of the worker workflow-outbound interceptor chain (spec R71):
# ABOUTME: runs the real schedule/signal/CAN/nexus/info via the input's _root cb.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Worker::Interceptor ();

# The chain root the workflow-outbound wrappers wrap (spec R71, parity finding
# 1; MUST-match sdk-python's _WorkflowOutboundImpl, the innermost outbound in
# worker/_interceptor.py:416-481's chain). Each method performs the real
# command emission by calling the private `_root` coderef the Runner stashed
# on the input, the same convention as Temporalio::Worker::_RootWorkflowInbound
# and the client's Temporalio::Client::_RootOutbound. The Runner hands this to
# $workflow_inbound->init(...); interceptor inbounds may wrap it on the way
# down, and the Runner routes the eight outbound operations through whatever
# reaches the root inbound.
#
# Its own file because only one `class :isa` parses cleanly per file once
# Future::AsyncAwait is loaded process-wide (see _RootWorkflowInbound); methods
# are signature-less for the same reason.
class Temporalio::Worker::_RootWorkflowOutbound
    :isa(Temporalio::Worker::WorkflowOutbound) {
    method execute_activity         { $_[0]->get('_root')->($_[0]) }
    method execute_local_activity   { $_[0]->get('_root')->($_[0]) }
    method start_child_workflow     { $_[0]->get('_root')->($_[0]) }
    method signal_child_workflow    { $_[0]->get('_root')->($_[0]) }
    method signal_external_workflow { $_[0]->get('_root')->($_[0]) }
    method continue_as_new          { $_[0]->get('_root')->($_[0]) }
    method start_nexus_operation    { $_[0]->get('_root')->($_[0]) }
    method info                     { $_[0]->get('_root')->($_[0]) }
}

1;
