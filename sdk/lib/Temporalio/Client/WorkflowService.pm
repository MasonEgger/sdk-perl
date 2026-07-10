# ABOUTME: Raw WorkflowService handle (spec R91): one snake_case method per
# ABOUTME: rpc, generated from the proto service descriptor, each a single
# ABOUTME: unretried bridge rpc-call over the connection. Python parity
# ABOUTME: _client.py:311-314 / services_generated.py WorkflowService.
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
class Temporalio::Client::WorkflowService {
    field $connection :param;    # Temporalio::Client::Connection

    ADJUST {
        Temporalio::Client::RawService::install_rpc_methods(
            __PACKAGE__, 'temporal.api.workflowservice.v1.WorkflowService');
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
            $rpc, $request, service => 'workflow', %opts);
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::WorkflowService - raw workflow service RPC handle

=head1 SYNOPSIS

    my $wf = $client->workflow_service;

    my $info = await $wf->get_system_info(
        Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.GetSystemInfoRequest')->new({}));

=head1 DESCRIPTION

The low-level escape hatch over the WorkflowService RPC surface (spec R91;
Python parity C<_client.py:311-314>): one snake_case method per rpc in
C<temporal.api.workflowservice.v1.WorkflowService>, generated from the
vendored proto service descriptor by L<Temporalio::Client::RawService>.
Each method takes a proto request message plus the C<rpc_call> options
(C<retry>, C<timeout>, ...) and returns a L<Future> resolving to the typed
response; calls are single-shot by default (C<< retry => 0 >>), matching
Python's raw services. The generated methods are documented collectively
here: the authoritative list is the vendored
C<temporal/api/workflowservice/v1/service.proto>.

Obtained from C<< $client->workflow_service >> (or
C<< $connection->workflow_service >>); not user-built.

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
