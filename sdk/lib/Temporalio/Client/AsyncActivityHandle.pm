# ABOUTME: Client-side handle (spec section 22) for an activity completing out
# ABOUTME: of band, addressed by opaque task token OR id reference (workflow_id
# ABOUTME: + optional run_id + activity_id). Async heartbeat/complete/fail/
# ABOUTME: report_cancellation pick the *ById* RPC for an id reference else the
# ABOUTME: task-token RPC, injecting namespace/identity from the client.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;

use Temporalio::Core::Proto ();
use Temporalio::Exception::Activity::AsyncActivityCancelled ();

class Temporalio::Client::AsyncActivityHandle {
    # The owning Temporalio::Client (namespace/identity/data_converter + _rpc_call).
    field $client :param;

    # Exactly one of these is defined (validated by the factory):
    #   $task_token   — raw bytes addressing the activity
    #   $id_reference — { workflow_id => ..., run_id => ..., activity_id => ... }
    field $task_token   :param = undef;
    field $id_reference :param = undef;

    method task_token   { $task_token }
    method id_reference { $id_reference }

    # ----- request builders (async because details/result/failure convert
    # through the data converter). Each returns the proto request message,
    # picking the *ById* variant for an id reference. Set only the fields the
    # spec calls out (task_token/namespace/identity + payload/failure); the
    # deprecated worker_version/deployment/resource_id fields stay absent.

    async method _build_heartbeat_request (@details) {
        my $payloads = await $self->_payloads(\@details);
        if (defined $task_token) {
            return _resolve('RecordActivityTaskHeartbeatRequest')->new({
                task_token => $task_token,
                namespace  => $client->namespace,
                identity   => $client->identity,
                (defined $payloads ? (details => $payloads) : ()),
            });
        }
        return _resolve('RecordActivityTaskHeartbeatByIdRequest')->new({
            %{ $self->_id_fields },
            (defined $payloads ? (details => $payloads) : ()),
        });
    }

    async method _build_complete_request (@result) {
        # complete() sends no result field; complete($x) converts $x. @result
        # is 0 or 1 element. T-asyncact-9 exercises the no-result path.
        my $payloads = @result ? await $self->_payloads([ $result[0] ]) : undef;
        if (defined $task_token) {
            return _resolve('RespondActivityTaskCompletedRequest')->new({
                task_token => $task_token,
                namespace  => $client->namespace,
                identity   => $client->identity,
                (defined $payloads ? (result => $payloads) : ()),
            });
        }
        return _resolve('RespondActivityTaskCompletedByIdRequest')->new({
            %{ $self->_id_fields },
            (defined $payloads ? (result => $payloads) : ()),
        });
    }

    async method _build_fail_request ($error, %opts) {
        my $last = delete $opts{last_heartbeat_details} // [];
        my $failure   = await $client->data_converter->to_failure($error);
        my $hb_payloads = @$last ? await $self->_payloads($last) : undef;
        if (defined $task_token) {
            return _resolve('RespondActivityTaskFailedRequest')->new({
                task_token => $task_token,
                namespace  => $client->namespace,
                identity   => $client->identity,
                failure    => $failure,
                (defined $hb_payloads
                    ? (last_heartbeat_details => $hb_payloads) : ()),
            });
        }
        return _resolve('RespondActivityTaskFailedByIdRequest')->new({
            %{ $self->_id_fields },
            failure => $failure,
            (defined $hb_payloads
                ? (last_heartbeat_details => $hb_payloads) : ()),
        });
    }

    async method _build_report_cancellation_request (@details) {
        my $payloads = await $self->_payloads(\@details);
        if (defined $task_token) {
            return _resolve('RespondActivityTaskCanceledRequest')->new({
                task_token => $task_token,
                namespace  => $client->namespace,
                identity   => $client->identity,
                (defined $payloads ? (details => $payloads) : ()),
            });
        }
        return _resolve('RespondActivityTaskCanceledByIdRequest')->new({
            %{ $self->_id_fields },
            (defined $payloads ? (details => $payloads) : ()),
        });
    }

    # ----- public RPC methods (spec section 22.1). All route through
    # _rpc_call (service => 'workflow', retry => 1).

    async method heartbeat (@details) {
        my $request = await $self->_build_heartbeat_request(@details);
        my $response = await $client->_rpc_call(
            ($self->_by_id ? 'RecordActivityTaskHeartbeatById'
                           : 'RecordActivityTaskHeartbeat'),
            $request, service => 'workflow', retry => 1);
        if (my $cancelled = _cancellation_from_response($response)) {
            die $cancelled;
        }
        return;
    }

    async method complete (@result) {
        my $request = await $self->_build_complete_request(@result);
        await $client->_rpc_call(
            ($self->_by_id ? 'RespondActivityTaskCompletedById'
                           : 'RespondActivityTaskCompleted'),
            $request, service => 'workflow', retry => 1);
        return;
    }

    async method fail ($error, %opts) {
        my $request = await $self->_build_fail_request($error, %opts);
        await $client->_rpc_call(
            ($self->_by_id ? 'RespondActivityTaskFailedById'
                           : 'RespondActivityTaskFailed'),
            $request, service => 'workflow', retry => 1);
        return;
    }

    async method report_cancellation (@details) {
        my $request = await $self->_build_report_cancellation_request(@details);
        await $client->_rpc_call(
            ($self->_by_id ? 'RespondActivityTaskCanceledById'
                           : 'RespondActivityTaskCanceled'),
            $request, service => 'workflow', retry => 1);
        return;
    }

    # ----- helpers -----

    method _by_id { defined $id_reference ? 1 : 0 }

    # Common namespace/identity + id triple for the ById request variants.
    method _id_fields {
        return {
            namespace   => $client->namespace,
            identity    => $client->identity,
            workflow_id => $id_reference->{workflow_id},
            (defined $id_reference->{run_id}
                ? (run_id => $id_reference->{run_id}) : ()),
            activity_id => $id_reference->{activity_id},
        };
    }

    # \@values -> a temporal.api.common.v1.Payloads, or undef when empty. Async
    # because the data converter encodes (sync path, matching v0.1 heartbeat).
    async method _payloads ($values) {
        return undef unless @$values;
        my @payloads = await $client->data_converter->to_payloads($values);
        return _resolve_common('Payloads')->new({ payloads => [@payloads] });
    }

    # ----- file-scope subs (compile into main:: under a bare `class`) -----

    sub _resolve ($short) {
        return Temporalio::Core::Proto::resolve(
            "temporal.api.workflowservice.v1.$short");
    }

    sub _resolve_common ($short) {
        return Temporalio::Core::Proto::resolve("temporal.api.common.v1.$short");
    }

    # Inspect a heartbeat response: if any of cancel_requested/activity_paused/
    # activity_reset is set, build (do NOT throw) the AsyncActivityCancelled
    # exception carrying the flags. Returns undef when none are set. Shared by
    # heartbeat and exercised directly in the unit test.
    sub _cancellation_from_response ($response) {
        my $cancel = $response->cancel_requested ? 1 : 0;
        my $paused = $response->activity_paused  ? 1 : 0;
        my $reset  = $response->activity_reset   ? 1 : 0;
        return undef unless $cancel || $paused || $reset;
        return Temporalio::Exception::Activity::AsyncActivityCancelled->new(
            message          => 'async activity cancellation requested',
            cancel_requested => $cancel,
            activity_paused  => $paused,
            activity_reset   => $reset,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::AsyncActivityHandle - complete an out-of-band activity

=head1 SYNOPSIS

    my $h = $client->async_activity_handle(task_token => $bytes);
    my $h = $client->async_activity_handle(
        workflow_id => $w, run_id => $r, activity_id => $a);

    await $h->heartbeat(@details);          # may throw AsyncActivityCancelled
    await $h->complete($result);            # $result optional
    await $h->fail($error, last_heartbeat_details => \@details);
    await $h->report_cancellation(@details);

=head1 DESCRIPTION

A client-side handle (spec section 22) to an activity that declared it will
complete B<out of band> (via L<Temporalio::Activity/complete_async>). The
activity is addressed either by its opaque B<task token> or by an B<id
reference> (C<workflow_id> + optional C<run_id> + C<activity_id>); the two are
mutually exclusive. Construct one with
L<Temporalio::Client/async_activity_handle> — there is no RPC at construction.

Each method picks the C<*ById*> RPC for an id reference, else the task-token
RPC, and injects the client's C<namespace> and C<identity> on every request.
RPCs route through C<_rpc_call> (C<service =E<gt> 'workflow'>, C<retry =E<gt>
1>). Details, results, and last-heartbeat details convert through the client's
data converter.

C<heartbeat> inspects the response: when the server sets C<cancel_requested>,
C<activity_paused>, and/or C<activity_reset>, it raises
L<Temporalio::Exception::Activity::AsyncActivityCancelled> carrying the flags.
This is the only cancellation-delivery channel to an out-of-band activity.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Client::AsyncActivityHandle->new(
        client       => $client,
        task_token   => $bytes,        # xor id_reference
        id_reference => { workflow_id => ..., run_id => ..., activity_id => ... },
    );

Constructs the handle. Prefer L<Temporalio::Client/async_activity_handle>,
which validates the token-xor-id union.

=head1 METHODS

=head2 task_token

The opaque task token this handle addresses, or C<undef> for an id-reference handle.

=head2 id_reference

The C<{ workflow_id, run_id, activity_id }> hashref this handle addresses, or
C<undef> for a task-token handle.

=head2 heartbeat

Async. Records a heartbeat with the given details. Raises
L<Temporalio::Exception::Activity::AsyncActivityCancelled> if the response signals
cancel/pause/reset.

=head2 complete

Async. Completes the activity. The result argument is optional (a no-result
activity sends an absent result field).

=head2 fail

Async. Fails the activity with the given error. C<last_heartbeat_details> (an
arrayref, default empty) is stored as the last heartbeat.

=head2 report_cancellation

Async. Reports the activity as cancelled, with optional cancellation details.

=cut
