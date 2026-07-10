# ABOUTME: Decode-only schedule description (spec section 25): id, schedule,
# ABOUTME: info, typed search attributes, lazy memo, and the raw proto response.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Schedule::Schedule ();
use Temporalio::Schedule::Info ();

class Temporalio::Schedule::Description {
    field $id                :param;
    field $schedule          :param;
    field $info              :param;
    field $search_attributes :param = undef;    # decoded (typed)
    field $raw_description   :param = undef;     # the raw DescribeScheduleResponse
    field $client            :param = undef;     # for lazy memo decode

    method id                { $id }
    method schedule          { $schedule }
    method info              { $info }
    method search_attributes { $search_attributes }
    method raw_description   { $raw_description }

    # memo — async; decoded lazily from the raw response on first access.
    async method memo {
        return {} unless defined $raw_description && defined $client;
        my $memo = $raw_description->memo;
        return {} unless defined $memo;
        my $fields = $memo->fields // {};
        my %out;
        for my $key (keys %$fields) {
            ($out{$key}) =
                await $client->data_converter->from_payloads([ $fields->{$key} ]);
        }
        return \%out;
    }

    # _from_proto($id, $response, $client) — class method building a Description
    # from a DescribeScheduleResponse.
    sub _from_proto ($class, $id, $response, $client = undef) {
        return $class->new(
            id              => $id,
            schedule        =>
                Temporalio::Schedule::Schedule->_from_proto($response->schedule),
            info            =>
                Temporalio::Schedule::Info->_from_proto($response->info),
            raw_description => $response,
            client          => $client,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::Description - a decoded schedule description

=head1 DESCRIPTION

A decode-only schedule description (spec section 25) returned by
C<< $handle->describe >>. It carries the schedule id, the decoded
L<Temporalio::Schedule::Schedule>, the L<Temporalio::Schedule::Info>, and the
raw C<DescribeScheduleResponse> for round-trip fidelity. The action's workflow
arguments are held as raw Payloads inside the schedule so a
describe-modify-update cycle re-emits identical bytes. Schedule-level search
attributes are decoded eagerly; the memo decodes lazily via the async C<memo>
method.

=head1 CONSTRUCTOR

=head2 new

    my $d = Temporalio::Schedule::Description->new(%fields);

Named parameters: C<id> (required), C<schedule> (required), C<info>
(required), C<search_attributes>, C<raw_description>, C<client>.

=head1 METHODS

=head2 id

Accessor returning the schedule id.

=head2 schedule

Accessor returning the decoded schedule.

=head2 info

Accessor returning the schedule info.

=head2 search_attributes

Accessor returning the decoded typed search attributes.

=head2 raw_description

Accessor returning the raw C<DescribeScheduleResponse> proto.

=head2 memo

Async. Returns a L<Future> resolving to the lazily-decoded memo hashref.

=cut
