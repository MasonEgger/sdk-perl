# ABOUTME: Unsafe workflow escapes (spec section 27.4 / 29.4): durable_scheduler_disabled
# ABOUTME: and illegal_call_tracing_disabled - run a block outside a determinism contract.
package Temporalio::Workflow::Unsafe;

use v5.38;
use warnings;

use Syntax::Keyword::Dynamically;

use Temporalio::Workflow::DeterminismGuard ();

# illegal_call_tracing_disabled($code) - run $code with the determinism guard
# suppressed, returning whatever $code returns. While the block runs, the
# guard's time/entropy overrides delegate straight to the real builtin even
# inside workflow context (spec §29.4). The suppression is dynamically scoped
# (Syntax::Keyword::Dynamically, never `local` - Future::AsyncAwait panics on
# `local`, spec §16.1) so it unwinds correctly across an await and does NOT leak
# past the block. Outside a workflow body the guard already delegates, so this is
# effectively transparent; it is still valid to call there. Mirrors sdk-ruby's
# Workflow::Unsafe.illegal_call_tracing_disabled.
sub illegal_call_tracing_disabled ($code) {
    dynamically $Temporalio::Workflow::DeterminismGuard::SUPPRESS_DEPTH
        = $Temporalio::Workflow::DeterminismGuard::SUPPRESS_DEPTH + 1;
    return $code->();
}

# durable_scheduler_disabled($code) - run $code with the durable scheduler
# disabled, returning whatever $code returns. "Disabled" means: while the block
# runs, the runner does not record commands on / yield to the deterministic
# scheduler. This is the escape hatch the OpenTelemetry tracing interceptor uses
# for span attach/extract that touches a mutex or real wall-clock time inside a
# workflow activation, so that work never becomes part of the recorded history
# (spec section 27.4 resolved decision).
#
# Outside a workflow body (no active runner) the block simply runs - there is no
# scheduler to disable. Inside a workflow body it delegates to the runner's
# durable_scheduler_disabled method, which dynamically raises a suppression
# depth for the duration of the block. The block is run in the caller's list
# context expectation via the runner; here we keep it scalar-or-list transparent
# by forwarding directly.
sub durable_scheduler_disabled ($code) {
    my $runner = $Temporalio::Workflow::Runner::CURRENT;
    return $runner->durable_scheduler_disabled($code) if defined $runner;
    return $code->();
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::Unsafe - unsafe workflow escapes (spec section 27.4 / 29.4)

=head1 DESCRIPTION

Holds escape hatches that step outside the deterministic workflow contract. They
are "unsafe" because misuse breaks determinism; use them only as the SDK does.

=head1 FUNCTIONS

=head2 illegal_call_tracing_disabled

C<< Temporalio::Workflow::Unsafe::illegal_call_tracing_disabled($code) >> runs
C<$code> with the determinism guard suppressed and returns its result. While the
block runs, the guard's time/entropy overrides
(L<Temporalio::Workflow::DeterminismGuard>) delegate straight to the real
builtin even inside a workflow body. Use it only when a call into a third-party
library provably does not affect workflow determinism. The suppression is
dynamically scoped, so it unwinds across an C<await> and does not leak past the
block. Outside a workflow body the block simply runs.

=head2 durable_scheduler_disabled

C<< Temporalio::Workflow::Unsafe::durable_scheduler_disabled($code) >> runs
C<$code> with the durable scheduler disabled and returns its result. While the
block runs, the runner neither records commands on nor yields to the
deterministic scheduler. The L<Temporalio::Contrib::OpenTelemetry::TracingInterceptor>
uses it for OpenTelemetry span attach/extract that touches a mutex or real
wall-clock time inside a workflow activation, so that work never enters the
recorded history. Outside a workflow body the block simply runs.

=cut
