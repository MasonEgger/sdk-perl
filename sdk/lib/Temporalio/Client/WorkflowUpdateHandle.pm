# ABOUTME: Handle to a started workflow update (spec section 19): carries the
# ABOUTME: update ref and any known outcome; result() polls to completion via
# ABOUTME: PollWorkflowExecutionUpdate and decodes the outcome or throws.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Common::Options ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Server ();
use Temporalio::Exception::WorkflowUpdateFailed ();

class Temporalio::Client::WorkflowUpdateHandle {
    # temporal.api.enums.v1.UpdateWorkflowExecutionLifecycleStage: COMPLETED == 3.
    # result() polls with this stage so the server blocks until the update has a
    # final outcome (spec section 19.2).
    my $STAGE_COMPLETED = 3;

    field $client      :param;
    field $workflow_id :param;
    field $run_id      :param = undef;
    field $update_id   :param;

    # The Outcome proto (temporal.api.update.v1.Outcome) if the update has
    # already completed when the handle was created (the start RPC may return it
    # in the same call), else undef. result() returns it directly when present.
    field $known_outcome :param = undef;

    method client      { $client }
    method workflow_id { $workflow_id }
    method run_id      { $run_id }
    method update_id   { $update_id }

    # result() — async (spec section 19.2). Returns the decoded update result, or
    # throws Temporalio::Exception::WorkflowUpdateFailed (cause = decoded failure)
    # for a failed outcome. If the outcome is already known it is decoded
    # directly; otherwise PollWorkflowExecutionUpdate is long-polled with the
    # COMPLETED wait stage (looping on a transient/empty response like result()'s
    # long-poll) until an outcome is returned.
    async method result (%opts) {
        # One strictness rule across the client surface (spec R44, finding
        # A10): this method takes no options; any key is a typo and raises.
        Temporalio::Common::Options::assert_known_keys(
            'WorkflowUpdateHandle->result', \%opts, {});
        my $outcome = $known_outcome;
        if (!defined $outcome) {
            $outcome = await $self->_poll_until_outcome;
        }
        return await $self->_decode_outcome($outcome);
    }

    # Poll PollWorkflowExecutionUpdate with the COMPLETED wait stage until the
    # response carries an outcome. The server's max wait may return early without
    # one (UNSPECIFIED stage); loop and re-poll (spec section 19.2).
    async method _poll_until_outcome {
        my $UpdateRef =
            _resolve('temporal.api.update.v1.UpdateRef');
        my $WaitPolicy =
            _resolve('temporal.api.update.v1.WaitPolicy');

        while (1) {
            my $request = _resolve(
                'temporal.api.workflowservice.v1.PollWorkflowExecutionUpdateRequest')
                ->new({
                    namespace  => $client->namespace,
                    identity   => $client->identity,
                    update_ref => $UpdateRef->new({
                        workflow_execution => $self->_execution_message,
                        update_id          => $update_id,
                    }),
                    wait_policy => $WaitPolicy->new({
                        lifecycle_stage => $STAGE_COMPLETED,
                    }),
                });
            my $response =
                await $client->_rpc_call('PollWorkflowExecutionUpdate', $request);
            if (defined(my $outcome = $response->outcome)) {
                return $outcome;
            }
            # No outcome yet (server max-wait expired before completion); re-poll.
        }
    }

    # Decode an Outcome proto: success -> the decoded single result payload (warn
    # on >1); failure -> throw WorkflowUpdateFailed (cause = decoded failure).
    async method _decode_outcome ($outcome) {
        my $which = $outcome->which_value // '';
        if ($which eq 'failure') {
            my $cause = await $client->data_converter->from_failure(
                $outcome->failure);
            Temporalio::Exception::WorkflowUpdateFailed->throw(
                message => 'Workflow update failed',
                cause   => $cause,
            );
        }
        if ($which eq 'success') {
            my $payloads = $outcome->success;
            my @values = await $self->_decode_all_payloads($payloads);
            if (@values > 1) {
                warn "Temporalio::Client::WorkflowUpdateHandle: update outcome "
                   . "carried " . scalar(@values) . " result payloads; using the "
                   . "first\n";
            }
            return $values[0];
        }
        Temporalio::Exception::Server->throw(
            message => 'Update outcome has neither success nor failure');
    }

    method _execution_message () {
        return _resolve('temporal.api.common.v1.WorkflowExecution')->new({
            workflow_id => $workflow_id,
            run_id      => $run_id // '',
        });
    }

    async method _decode_all_payloads ($payloads_msg) {
        return () unless defined $payloads_msg;
        my $payloads = $payloads_msg->payloads;
        return () unless defined $payloads && @$payloads;
        return await $client->data_converter->from_payloads($payloads);
    }

    sub _resolve ($name) { Temporalio::Core::Proto::resolve($name) }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::WorkflowUpdateHandle - handle to a started workflow update

=head1 SYNOPSIS

    my $uh = await $handle->start_update(
        'add', [5], wait_for_stage => 'accepted');
    my $r  = await $uh->result;     # polls to completion, returns the result

=head1 DESCRIPTION

A reference to a single workflow update (spec section 19), returned by
C<< $workflow_handle->start_update >>. It carries the C<workflow_id>, C<run_id>,
and C<update_id> plus a back-reference to the owning L<Temporalio::Client>, and
any C<known_outcome> the start RPC already returned.

=head2 result

C<< await $uh->result >> returns the decoded update result. When the outcome is
already known (the start RPC returned it) it is decoded directly; otherwise
C<PollWorkflowExecutionUpdate> is long-polled with the C<COMPLETED> wait stage
until an outcome is available. A failed outcome raises
L<Temporalio::Exception::WorkflowUpdateFailed> whose C<cause> is the decoded
validator/handler failure.

=head1 METHODS

=head2 client

Accessor returning the owning L<Temporalio::Client>.

=head2 run_id

Accessor returning the workflow run id.

=head2 update_id

Accessor returning the update id.

=head2 workflow_id

Accessor returning the workflow id.

=head1 CONSTRUCTOR

=head2 new

    my $uh = Temporalio::Client::WorkflowUpdateHandle->new(
        client => $client, workflow_id => $id, run_id => $rid,
        update_id => $uid, known_outcome => $outcome);

Constructs a Temporalio::Client::WorkflowUpdateHandle. Normally created by
C<< $workflow_handle->start_update >> rather than directly.

=cut
