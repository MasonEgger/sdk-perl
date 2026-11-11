# ABOUTME: Raw HealthService handle (spec I12): the standard gRPC health
# ABOUTME: check rpc, generated from the proto service descriptor, a single
# ABOUTME: unretried bridge rpc-call. Python parity service.py:257,332.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Client::RawService ();

# Own file, no :isa: one class per compilation unit under Future::AsyncAwait
# (the _RootOutbound precedent). The per-rpc methods are installed by
# Temporalio::Client::RawService at first construction (generated from the
# proto service descriptor rather than hand-listed, parity audit client
# finding 1) and dispatch through the generic call() below, the only
# method that touches instance state. grpc.health.v1.Health's Watch rpc is
# server-streaming; install_rpc_methods skips it (Connection::rpc_call is
# unary-only), so only check() is generated here, matching Python's
# generated HealthService.
class Temporalio::Client::HealthService {
    field $connection :param;    # Temporalio::Client::Connection

    ADJUST {
        Temporalio::Client::RawService::install_rpc_methods(
            __PACKAGE__, 'grpc.health.v1.Health');
    }

    method connection { $connection }

    # call($rpc, $request, %opts) -> Future. Generic passthrough by CamelCase
    # rpc name; single-shot (retry => 0) unless the caller opts in, matching
    # Python's raw-service default retry=False. Signature-less: this class
    # holds a `field :param`, and mixing that with signatured methods trips
    # the 5.38 class parser under Future::AsyncAwait (lessons 2026-06-24).
    method call {
        my ($rpc, $request, %opts) = @_;
        return $connection->rpc_call(
            $rpc, $request, service => 'health', %opts);
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::HealthService - raw gRPC health-check service handle

=head1 SYNOPSIS

    my $health = $client->health_service;

    my $resp = await $health->check(
        Temporalio::Core::Proto::resolve(
            'grpc.health.v1.HealthCheckRequest')->new({}));

=head1 DESCRIPTION

The low-level escape hatch over the standard gRPC health-checking protocol
(spec I12; Python parity C<service.py:257,332>): a single C<check> method
over C<grpc.health.v1.Health>, generated from the vendored proto service
descriptor by L<Temporalio::Client::RawService>. The service's C<Watch> rpc
is server-streaming; C<Connection::rpc_call> is unary-only over the
c-bridge, so C<install_rpc_methods> skips it and only C<check> is generated,
matching Python's generated C<HealthService>. C<check> takes a proto request
message plus the C<rpc_call> options (C<retry>, C<timeout>, ...) and returns
a L<Future> resolving to the typed response; calls are single-shot by
default (C<< retry => 0 >>), matching Python's raw services.

Obtained from C<< $client->health_service >> (or
C<< $connection->health_service >>); not user-built.

=head1 METHODS

=head2 call($rpc, $request, %opts)

Generic passthrough: issues C<$rpc> (the CamelCase name the c-bridge
dispatches on) with the given request message over the connection, returning
a L<Future> resolving to the decoded response. The generated C<check> method
funnels through here; C<%opts> is the L<Temporalio::Client::Connection>
C<rpc_call> option set minus C<service>.

=head2 connection

Accessor returning the underlying L<Temporalio::Client::Connection>.

=cut
