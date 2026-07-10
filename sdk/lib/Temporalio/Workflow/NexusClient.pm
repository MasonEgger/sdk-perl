# ABOUTME: In-workflow Nexus client (spec section 26.1) bound to an endpoint +
# ABOUTME: service; start_operation / execute_operation schedule one operation.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;

# A NexusClient is constructed only by Temporalio::Workflow::create_nexus_client
# (spec section 26.1) — never directly by author code. It binds an endpoint + a
# service name and a back-reference to the Runner, and exposes the two operation
# entry points. start_operation delegates to the Runner (which allocates the
# nexus seq, converts the single arg / timeouts / cancellation_type / summary,
# emits the ScheduleNexusOperation command, and registers the start + result
# Futures in a NexusOperationHandle); it returns the start Future, so an
# `await $nc->start_operation(...)` resolves to the handle once the operation has
# started. execute_operation is sugar over start + ->result.
class Temporalio::Workflow::NexusClient {
    # The Nexus endpoint name (a server/operator-managed registry entry; passed
    # through as a plain string — there is no client-side endpoint creation, F4).
    field $endpoint :param;

    # The Nexus service name on that endpoint.
    field $service :param;

    # The owning Temporalio::Workflow::Runner (back-reference for command
    # emission and Future registration).
    field $runner :param;

    method endpoint { return $endpoint }
    method service  { return $service }

    # start_operation($operation, $arg, %opts) -> (async) the
    # NexusOperationHandle, resolved once the operation has STARTED (spec section
    # 26.1). $operation is the operation name; $arg is the SINGLE input value (the
    # proto carries one input Payload, not a list). %opts mirror spec section
    # 26.1: schedule_to_close_timeout / schedule_to_start_timeout /
    # start_to_close_timeout (seconds), cancellation_type (default
    # wait_cancellation_completed), summary (-> user_metadata), headers (->
    # nexus_header string map). Like start_child_workflow this is `async` and
    # itself awaited: it suspends on the runner's start Future until
    # ResolveNexusOperationStart arrives, then resolves to the handle.
    async method start_operation ($operation, $arg = undef, %opts) {
        my $handle = await $runner->start_nexus_operation(
            endpoint  => $endpoint,
            service   => $service,
            operation => $operation,
            arg       => $arg,
            %opts,
        );
        return $handle;
    }

    # execute_operation($operation, $arg, %opts) -> (async) the operation's
    # result value (spec section 26.1). Sugar over start_operation + ->result:
    # awaits the start, then awaits the result. A result failure raises
    # Temporalio::Exception::NexusOperation at this await site (spec section 26.4).
    async method execute_operation ($operation, $arg = undef, %opts) {
        my $handle = await $self->start_operation($operation, $arg, %opts);
        return await $handle->result;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::NexusClient - in-workflow Nexus client (spec section 26.1)

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use Temporalio::Workflow;

    my $nc = Temporalio::Workflow::create_nexus_client(
        endpoint => 'my-endpoint', service => 'my-service');

    # async start, then await the result via the handle:
    my $handle = await $nc->start_operation('say-hello', 'world');
    my $result = await $handle->result;

    # or one-shot:
    my $result = await $nc->execute_operation(
        'say-hello', 'world', schedule_to_close_timeout => 60);

=head1 DESCRIPTION

Constructed only by C<Temporalio::Workflow::create_nexus_client> (spec section
26.1); never instantiated directly. Binds an endpoint and service name and
delegates operation scheduling to the L<Temporalio::Workflow::Runner>. The proto
carries a B<single> input Payload, so C<start_operation> /
C<execute_operation> take one positional C<$arg> (not an C<args> arrayref).

=head1 CONSTRUCTOR

=head2 new

    my $nc = Temporalio::Workflow::NexusClient->new(
        endpoint => ..., service => ..., runner => ...);

Constructed only by C<Temporalio::Workflow::create_nexus_client>; not called by
author code.

=head1 METHODS

=head2 endpoint

The Nexus endpoint name this client is bound to.

=head2 service

The Nexus service name this client is bound to.

=head2 start_operation

C<start_operation($operation, $arg, %opts)> schedules one Nexus operation and
returns (async) the L<Temporalio::Workflow::NexusOperationHandle> once the
operation has started. C<$operation> is the operation name; C<$arg> is the single
input value. C<%opts>: C<schedule_to_close_timeout>, C<schedule_to_start_timeout>,
C<start_to_close_timeout> (seconds), C<cancellation_type> (default
C<wait_cancellation_completed>), C<summary>, C<headers> (the C<nexus_header>
string map, B<not> Temporal-header Payloads).

=head2 execute_operation

C<execute_operation($operation, $arg, %opts)> is sugar over C<start_operation> +
C<< ->result >>: it returns (async) the operation's result value, raising
L<Temporalio::Exception::NexusOperation> on a failed/timed-out/cancelled
operation. Accepts the same C<%opts> as C<start_operation>.

=head1 SEE ALSO

L<Temporalio::Workflow>, L<Temporalio::Workflow::NexusOperationHandle>,
L<Temporalio::Workflow::Runner>, spec section 26.

=cut
