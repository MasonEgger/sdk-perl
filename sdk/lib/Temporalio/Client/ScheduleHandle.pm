# ABOUTME: Handle to a schedule (spec section 25): id/client readers plus the
# ABOUTME: schedule operations describe/delete/backfill/trigger/pause/unpause/
# ABOUTME: update, each funnelling through the client RPC path (P8.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Schedule::Description ();
use Temporalio::Schedule::Update ();

class Temporalio::Client::ScheduleHandle {
    field $client :param;
    field $id     :param;

    # Explicit readers (field :reader needs perl 5.40+; floor is 5.38).
    method client { $client }
    method id     { $id }

    # describe — async (spec section 25.2). Issues DescribeSchedule and decodes
    # the response into a Schedule::Description. The action's workflow args are
    # held RAW inside the schedule (no eager decode) so describe->modify->update
    # re-emits identical payloads; schedule-level search attributes decode
    # eagerly, memo lazily (see Description).
    async method describe {
        my $request = _resolve(
            'temporal.api.workflowservice.v1.DescribeScheduleRequest')->new({
                namespace   => $client->namespace,
                schedule_id => $id,
            });
        my $response = await $client->_rpc_call('DescribeSchedule', $request);
        return Temporalio::Schedule::Description->_from_proto($id, $response,
            $client);
    }

    # delete — async (spec section 25.2). DeleteScheduleRequest has NO
    # request_id (unlike the other write ops).
    async method delete {
        my $request = _resolve(
            'temporal.api.workflowservice.v1.DeleteScheduleRequest')->new({
                namespace   => $client->namespace,
                schedule_id => $id,
                identity    => $client->identity,
            });
        await $client->_rpc_call('DeleteSchedule', $request);
        return;
    }

    # backfill(@backfills) — async (spec section 25.2). At least one backfill is
    # required (empty -> Argument before any RPC). PatchSchedule carrying a
    # SchedulePatch with the backfill_request list.
    async method backfill (@backfills) {
        Temporalio::Exception::Argument->throw(
            message => 'backfill requires at least one Schedule::Backfill')
            unless @backfills;
        my $patch = _resolve('temporal.api.schedule.v1.SchedulePatch')->new({
            backfill_request => [ map { $_->_to_proto } @backfills ],
        });
        await $self->_patch($patch);
        return;
    }

    # trigger(overlap => undef) — async (spec section 25.2). Fires one action
    # immediately, even while the schedule is paused. The overlap override
    # defaults to unspecified (0) when not given.
    async method trigger (%opts) {
        my $overlap = delete $opts{overlap};
        if (my @unknown = sort keys %opts) {
            Temporalio::Exception::Argument->throw(
                message => 'unknown trigger option(s): ' . join(', ', @unknown));
        }
        my $trigger = _resolve(
            'temporal.api.schedule.v1.TriggerImmediatelyRequest')->new({
                overlap_policy =>
                    Temporalio::Schedule::Policy::overlap_enum($overlap),
            });
        my $patch = _resolve('temporal.api.schedule.v1.SchedulePatch')->new({
            trigger_immediately => $trigger,
        });
        await $self->_patch($patch);
        return;
    }

    # pause(note => 'Paused via Perl SDK') — async (spec section 25.2). The
    # SchedulePatch `pause` string both flips the paused state and sets notes.
    async method pause (%opts) {
        my $note = delete $opts{note} // 'Paused via Perl SDK';
        if (my @unknown = sort keys %opts) {
            Temporalio::Exception::Argument->throw(
                message => 'unknown pause option(s): ' . join(', ', @unknown));
        }
        my $patch = _resolve('temporal.api.schedule.v1.SchedulePatch')->new({
            pause => $note,
        });
        await $self->_patch($patch);
        return;
    }

    # unpause(note => 'Unpaused via Perl SDK') — async (spec section 25.2).
    async method unpause (%opts) {
        my $note = delete $opts{note} // 'Unpaused via Perl SDK';
        if (my @unknown = sort keys %opts) {
            Temporalio::Exception::Argument->throw(
                message => 'unknown unpause option(s): ' . join(', ', @unknown));
        }
        my $patch = _resolve('temporal.api.schedule.v1.SchedulePatch')->new({
            unpause => $note,
        });
        await $self->_patch($patch);
        return;
    }

    # update($updater) — async (spec section 25.2). Internal describe ->
    # Update::Input -> invoke the updater (may return a Schedule::Update, falsy,
    # or a Future to await); falsy -> no RPC; otherwise UpdateScheduleRequest
    # replacing spec/action/policies/state completely. SINGLE-SHOT: no
    # conflict-token retry loop (matches both reference SDKs — carry the same
    # TODO).
    async method update ($updater) {
        Temporalio::Exception::Argument->throw(
            message => 'update requires a callback coderef')
            unless ref $updater eq 'CODE';

        my $description = await $self->describe;
        my $input = Temporalio::Schedule::Update::Input->new(
            description => $description);

        my $update = $updater->($input);
        # The updater may return a Future (async updater); await it.
        $update = await $update
            if Scalar::Util::blessed($update) && $update->isa('Future');

        # Falsy (undef / nothing) -> no RPC (spec section 25.2).
        return unless $update;

        Temporalio::Exception::Argument->throw(
            message => 'update callback must return a Temporalio::Schedule::Update '
                     . 'or a falsy value')
            unless Scalar::Util::blessed($update)
                && $update->isa('Temporalio::Schedule::Update');

        my %fields = (
            namespace   => $client->namespace,
            schedule_id => $id,
            schedule    => await $update->schedule->_to_proto($client),
            identity    => $client->identity,
            request_id  => Temporalio::Client::_new_uuid(),
        );

        # search_attributes replaced only when DEFINED (even an empty set
        # clears + re-encodes); undef leaves them unchanged.
        my $sa = $update->search_attributes;
        if (defined $sa) {
            $fields{search_attributes} =
                Temporalio::Client::_coerce_search_attributes($sa);
        }

        my $request = _resolve(
            'temporal.api.workflowservice.v1.UpdateScheduleRequest')
            ->new(\%fields);
        await $client->_rpc_call('UpdateSchedule', $request);
        return;
    }

    # _patch($schedule_patch) — async; the shared PatchSchedule funnel for
    # backfill/trigger/pause/unpause (they differ only in the SchedulePatch).
    async method _patch ($patch) {
        my $request = _resolve(
            'temporal.api.workflowservice.v1.PatchScheduleRequest')->new({
                namespace   => $client->namespace,
                schedule_id => $id,
                patch       => $patch,
                identity    => $client->identity,
                request_id  => Temporalio::Client::_new_uuid(),
            });
        await $client->_rpc_call('PatchSchedule', $request);
        return;
    }

    sub _resolve ($name) { Temporalio::Core::Proto::resolve($name) }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::ScheduleHandle - handle to a Temporal schedule

=head1 SYNOPSIS

    my $h = $client->get_schedule_handle('my-schedule');

    my $desc = await $h->describe;       # Temporalio::Schedule::Description
    await $h->pause(note => 'Paused via Perl SDK');
    await $h->unpause;
    await $h->trigger(overlap => 'allow_all');
    await $h->backfill($bf1, $bf2);
    await $h->update(sub ($input) { ... return $update or undef });
    await $h->delete;

=head1 DESCRIPTION

A handle to a schedule (spec section 25), mirroring
L<Temporalio::Client::WorkflowHandle>. Returned by
C<< $client->get_schedule_handle >> (no RPC) and
C<< $client->create_schedule >>. It exposes the C<id> and owning C<client>
plus the schedule operations, each funnelling through the client's
C<_rpc_call> RPC path.

=head1 CONSTRUCTOR

=head2 new

    my $h = Temporalio::Client::ScheduleHandle->new(client => $c, id => $id);

Named parameters: C<client> (required), C<id> (required).

=head1 METHODS

=head2 client

Accessor returning the owning client.

=head2 id

Accessor returning the schedule id.

=head2 describe

Async. Issues C<DescribeSchedule> and returns a L<Future> resolving to a
L<Temporalio::Schedule::Description>. The action's workflow arguments are held
as raw Payloads so a describe-modify-update cycle re-emits identical bytes.

=head2 delete

Async. Issues C<DeleteSchedule> (the request carries no C<request_id>).
Returns a L<Future> resolving to nothing.

=head2 backfill

    await $h->backfill(@backfills);

Async. Backfills the schedule over one or more L<Temporalio::Schedule::Backfill>
windows via C<PatchSchedule>. At least one backfill is required; an empty list
raises L<Temporalio::Exception::Argument> before any RPC.

=head2 trigger

    await $h->trigger(overlap => undef);

Async. Triggers one action immediately via C<PatchSchedule>, even while the
schedule is paused. C<overlap> optionally overrides the schedule's overlap
policy (an OverlapPolicy string or proto number); it defaults to unspecified.

=head2 pause

    await $h->pause(note => 'Paused via Perl SDK');

Async. Pauses the schedule and sets its note via C<PatchSchedule>. The default
note is C<"Paused via Perl SDK">.

=head2 unpause

    await $h->unpause(note => 'Unpaused via Perl SDK');

Async. Unpauses the schedule and sets its note via C<PatchSchedule>. The
default note is C<"Unpaused via Perl SDK">.

=head2 update

    await $h->update(sub ($input) { ... });

Async. Updates the schedule using a callback. Internally describes the schedule,
hands the callback a L<Temporalio::Schedule::Update::Input> (carrying the current
C<description>), and expects the callback to return a
L<Temporalio::Schedule::Update> (or a L<Future> resolving to one) to apply, or a
falsy value to make no change. When applied, C<UpdateSchedule> replaces the
schedule's spec, action, policies, and state completely; search attributes are
replaced only when the update's C<search_attributes> is defined (even an empty
set clears them). The update is single-shot: there is no conflict-token retry
loop (matching the reference SDKs).

=cut
