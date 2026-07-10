# ABOUTME: Root of the worker activity-outbound interceptor chain (spec R72):
# ABOUTME: runs the real heartbeat/info via the input's private _root cb.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Worker::Interceptor ();

# The chain root the activity-outbound wrappers wrap (spec R72, parity finding
# 2; MUST-match sdk-python's _ActivityOutboundImpl, the innermost outbound in
# worker/_interceptor.py:135-156's chain). Each method performs the real work
# by calling the private `_root` coderef the Activity::Context stashed on the
# input — heartbeat's _root records through the context's heartbeat recorder,
# info's returns the frozen info hashref — the same convention as
# Temporalio::Worker::_RootActivityInbound and _RootWorkflowOutbound. The
# ActivityDispatcher hands this to $activity_inbound->init(...); interceptor
# inbounds may wrap it on the way down, and the context routes the body's
# heartbeat()/info() through whatever reaches the root inbound.
#
# Its own file because only one `class :isa` parses cleanly per file once
# Future::AsyncAwait is loaded process-wide (see _RootActivityInbound); methods
# are signature-less for the same reason.
class Temporalio::Worker::_RootActivityOutbound
    :isa(Temporalio::Worker::ActivityOutbound) {
    method info      { $_[0]->get('_root')->($_[0]) }
    method heartbeat { $_[0]->get('_root')->($_[0]) }
}

1;
