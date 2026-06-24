# ABOUTME: Unsafe workflow escapes (spec section 27.4 / 29.4) — durable_scheduler_disabled.
# ABOUTME: Runs a block without recording on / yielding to the durable scheduler.
package Temporalio::Workflow::Unsafe;

use v5.38;
use warnings;

# durable_scheduler_disabled($code) — run $code with the durable scheduler
# disabled, returning whatever $code returns. "Disabled" means: while the block
# runs, the runner does not record commands on / yield to the deterministic
# scheduler. This is the escape hatch the OpenTelemetry tracing interceptor uses
# for span attach/extract that touches a mutex or real wall-clock time inside a
# workflow activation, so that work never becomes part of the recorded history
# (spec section 27.4 resolved decision).
#
# Outside a workflow body (no active runner) the block simply runs — there is no
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

=head2 durable_scheduler_disabled

C<< Temporalio::Workflow::Unsafe::durable_scheduler_disabled($code) >> runs
C<$code> with the durable scheduler disabled and returns its result. While the
block runs, the runner neither records commands on nor yields to the
deterministic scheduler. The L<Temporalio::Contrib::OpenTelemetry::TracingInterceptor>
uses it for OpenTelemetry span attach/extract that touches a mutex or real
wall-clock time inside a workflow activation, so that work never enters the
recorded history. Outside a workflow body the block simply runs.

=cut
