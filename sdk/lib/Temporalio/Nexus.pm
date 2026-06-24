# ABOUTME: Nexus-handler author entry point (spec section 26.2) — `use Temporalio::Nexus;`.
# ABOUTME: Loads the definition base, exposes the handler context surface + gRPC->Nexus error table.
package Temporalio::Nexus;

use v5.38;
use warnings;

# A user Nexus module says `use Temporalio::Nexus;` and then declares
# `class My::Svc :isa(Temporalio::Nexus::Definition)`. Loading the base here
# means the author does not have to `use` it separately.
use Temporalio::Nexus::Definition ();
use Temporalio::Nexus::OperationContext ();
use Temporalio::Nexus::OperationResult ();
use Temporalio::Nexus::WorkflowHandle ();
use Temporalio::Exception::Runtime ();

# The Nexus handler context functional surface (spec section 26.2), mirroring
# the reference SDK's module functions (sdk-python nexus.info/client/logger).
# The current context is the dynamically-scoped $CURRENT, set by the dispatcher
# around the operation body. Calling info()/client()/logger() outside an
# operation raises; in_operation()/is_worker_shutdown() never raise.

# The current operation context (a StartOperationContext,
# WorkflowRunOperationContext, or CancelOperationContext). Set with
# `dynamically $Temporalio::Nexus::CURRENT = $ctx;` by the dispatcher.
our $CURRENT;

# Set by the dispatcher (dynamically) for the duration of worker shutdown drain.
our $IS_WORKER_SHUTDOWN = 0;

# context() -> the current operation context. Raises if not in an operation.
sub context () {
    my $ctx = $CURRENT;
    Temporalio::Exception::Runtime->throw(
        message => 'not in a Nexus operation context')
        unless defined $ctx;
    return $ctx;
}

# info() -> the current operation's Temporalio::Nexus::OperationInfo.
sub info () { context()->info }

# client() -> the worker's client (the one operations start workflows through).
sub client () { context()->client }

# logger() -> the handler logger for the current operation.
sub logger () { context()->logger }

# in_operation() -> bool: true when called inside an operation body.
sub in_operation () { defined $CURRENT ? 1 : 0 }

# is_worker_shutdown() -> bool: true once the worker has begun shutting down
# (the dispatcher sets this while draining remaining tasks; spec section 26.3).
sub is_worker_shutdown () { $IS_WORKER_SHUTDOWN ? 1 : 0 }

# ---------------------------------------------------------------------------
# gRPC status -> Nexus handler-error type (spec section 26.4 MUST-match table).
#
# Transcribed VERBATIM from sdk-python/temporalio/worker/_nexus.py:517-573
# (do NOT infer from the nexus HTTP spec). Returns ($type, $retryable_override)
# where $retryable_override is undef (use the type default), 0 (non-retryable),
# or 1 (retryable). The Nexus error-type strings match the nexusrpc
# HandlerErrorType names.
# ---------------------------------------------------------------------------
my %_GRPC_TO_NEXUS = (
    INVALID_ARGUMENT   => ['BAD_REQUEST',         undef],
    # ALREADY_EXISTS / FAILED_PRECONDITION / OUT_OF_RANGE -> INTERNAL non-retryable.
    ALREADY_EXISTS     => ['INTERNAL',            0],
    FAILED_PRECONDITION=> ['INTERNAL',            0],
    OUT_OF_RANGE       => ['INTERNAL',            0],
    # ABORTED / UNAVAILABLE -> UNAVAILABLE.
    ABORTED            => ['UNAVAILABLE',         undef],
    UNAVAILABLE        => ['UNAVAILABLE',         undef],
    # CANCELLED / DATA_LOSS / INTERNAL / UNKNOWN / UNAUTHENTICATED /
    # PERMISSION_DENIED -> INTERNAL (UNAUTHENTICATED/PERMISSION_DENIED are
    # converted to INTERNAL because this is a handler-to-Temporal auth failure,
    # retryable; see the python comment).
    CANCELLED          => ['INTERNAL',            undef],
    DATA_LOSS          => ['INTERNAL',            undef],
    INTERNAL           => ['INTERNAL',            undef],
    UNKNOWN            => ['INTERNAL',            undef],
    UNAUTHENTICATED    => ['INTERNAL',            undef],
    PERMISSION_DENIED  => ['INTERNAL',            undef],
    NOT_FOUND          => ['NOT_FOUND',           undef],
    RESOURCE_EXHAUSTED => ['RESOURCE_EXHAUSTED',  undef],
    UNIMPLEMENTED      => ['NOT_IMPLEMENTED',     undef],
    DEADLINE_EXCEEDED  => ['UPSTREAM_TIMEOUT',    undef],
);

# grpc_status_to_nexus_type($status_name) -> ($nexus_type, $retryable_override).
# Any unmapped status falls through to INTERNAL (python's `else` branch).
sub grpc_status_to_nexus_type ($status_name) {
    my $mapped = defined $status_name ? $_GRPC_TO_NEXUS{$status_name} : undef;
    return @$mapped if $mapped;
    return ('INTERNAL', undef);
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Nexus - entry point and handler context surface for Nexus services

=head1 SYNOPSIS

    use feature 'class';
    use Future::AsyncAwait;
    use Temporalio::Nexus;

    class My::NexusService :isa(Temporalio::Nexus::Definition) {
        method service_name :NexusService('test-service') ($) { }

        method say_hello :SyncOperation('say-hello') ($ctx, $name) {
            return "Hello, $name!";
        }
    }

    # inside a handler:
    my $info = Temporalio::Nexus::info;          # OperationInfo
    my $cli  = Temporalio::Nexus::client;        # worker client

=head1 DESCRIPTION

The Nexus author entry point (spec section 26.2). C<use Temporalio::Nexus;>
loads L<Temporalio::Nexus::Definition> (so C<:isa(...)> resolves) and the
context modules, and exposes the handler context functions.

=head2 Context functions

=over 4

=item C<info> / C<client> / C<logger>

The current operation's info, client, and logger. Raise
L<Temporalio::Exception::Runtime> when called outside an operation body.

=item C<in_operation>

True when called inside an operation body.

=item C<is_worker_shutdown>

True once the worker has begun shutting down.

=back

=head2 gRPC to Nexus error mapping

=over 4

=item C<grpc_status_to_nexus_type($status_name)>

Maps a gRPC status name (e.g. C<NOT_FOUND>) to its Nexus handler-error type and
optional retryable override, per the MUST-match table in spec section 26.4
(transcribed from sdk-python C<worker/_nexus.py>). Unmapped statuses map to
C<INTERNAL>.

=back

=head1 FUNCTIONS

=head2 context

Returns the current operation context, raising outside an operation.

=head2 info

The current L<Temporalio::Nexus::OperationInfo>.

=head2 client

The worker's client.

=head2 logger

The handler logger.

=head2 in_operation

True inside an operation body.

=head2 is_worker_shutdown

True once the worker is shutting down.

=head2 grpc_status_to_nexus_type

C<< grpc_status_to_nexus_type($status_name) >> returns C<< ($nexus_type, $retryable_override) >>.

=cut
