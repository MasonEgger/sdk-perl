# ABOUTME: Raw CloudService handle (spec I12): one snake_case method per rpc
# ABOUTME: (users, namespaces, service accounts, billing, audit logs, ...),
# ABOUTME: generated from the proto service descriptor, each a single
# ABOUTME: unretried bridge rpc-call. Python parity service.py:255,326.
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
# method that touches instance state.
class Temporalio::Client::CloudService {
    field $connection :param;    # Temporalio::Client::Connection

    ADJUST {
        Temporalio::Client::RawService::install_rpc_methods(
            __PACKAGE__, 'temporal.api.cloud.cloudservice.v1.CloudService');
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
            $rpc, $request, service => 'cloud', %opts);
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::CloudService - raw cloud service RPC handle

=head1 SYNOPSIS

    my $cloud = $client->cloud_service;

    my $users = await $cloud->get_users(
        Temporalio::Core::Proto::resolve(
            'temporal.api.cloud.cloudservice.v1.GetUsersRequest')->new({}));

=head1 DESCRIPTION

The low-level escape hatch over the Temporal Cloud CloudService RPC surface
(spec I12; Python parity C<service.py:255,326>): one snake_case method per
rpc in C<temporal.api.cloud.cloudservice.v1.CloudService> (users, namespaces,
service accounts, API keys, billing, usage, audit logs, connectivity rules,
and Nexus endpoint management), generated from the vendored proto service
descriptor by L<Temporalio::Client::RawService>. Each method takes a proto
request message plus the C<rpc_call> options (C<retry>, C<timeout>, ...) and
returns a L<Future> resolving to the typed response; calls are single-shot by
default (C<< retry => 0 >>), matching Python's raw services. The generated
methods are documented collectively here: the authoritative list is the
vendored C<temporal/api/cloud/cloudservice/v1/service.proto>.

Obtained from C<< $client->cloud_service >> (or
C<< $connection->cloud_service >>); not user-built. Talks to
C<saas-api.tmprl.cloud>, not a self-hosted Temporal server; a connection
built against a self-hosted server has no cloud service behind it.

=head1 METHODS

=head2 call($rpc, $request, %opts)

Generic passthrough: issues C<$rpc> (the CamelCase name the c-bridge
dispatches on) with the given request message over the connection, returning
a L<Future> resolving to the decoded response. The generated per-rpc methods
all funnel through here; C<%opts> is the L<Temporalio::Client::Connection>
C<rpc_call> option set minus C<service>.

=head2 connection

Accessor returning the underlying L<Temporalio::Client::Connection>.

=cut
