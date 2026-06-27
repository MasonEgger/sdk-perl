# ABOUTME: The one header-representation contract shared by the outbound and
# ABOUTME: inbound interceptor paths (#10 C-ICEPT-ACTIVITY-HEADERS). Headers
# ABOUTME: travel as Str => Payload maps in BOTH directions; an already-Payload
# ABOUTME: value passes through unchanged (never re-encoded / double-encoded).
package Temporalio::Interceptor::Headers;

use v5.38;
use warnings;

use Scalar::Util ();
use Temporalio::Core::Proto ();

# Resolved once: the generated temporal.api.common.v1.Payload message class.
# Payloads produced by the data converter (Temporalio::Payload) AND payloads
# materialized off the wire inside other messages (header_fields on an activity
# Start, headers on an InitializeWorkflow job) are both instances of — or
# subclasses of — this class, so an `isa` check covers both. Resolving it
# triggers the one-time vendored-proto load.
my $PAYLOAD_CLASS;
sub _payload_class {
    return $PAYLOAD_CLASS //=
        Temporalio::Core::Proto::resolve('temporal.api.common.v1.Payload');
}

# is_payload($value) — true when $value is already a Temporal Payload and so
# must be carried through the header map AS-IS. The header contract (matching
# sdk-python, whose ExecuteActivityInput/ExecuteWorkflowInput.headers is a
# Mapping[str, Payload]) is that a header VALUE is a Payload: context
# propagation sets it via the payload converter on the way out and reads it via
# the payload converter on the way in. Re-running such a value through
# to_payload would double-encode it (#10 GAP B).
sub is_payload ($value) {
    return Scalar::Util::blessed($value) && $value->isa(_payload_class());
}

# to_payload_map($payload_converter, $map) — encode a { name => value } header
# map to the wire shape { name => Payload }. A value that is ALREADY a Payload
# passes through untouched (#10 GAP B: no double-encode); a raw value is encoded
# exactly once. Used by every outbound header-emitting path (schedule_activity,
# schedule_local_activity, child-workflow start, continue-as-new) so they share
# one contract with the inbound paths, which thread their proto Str => Payload
# header maps through directly (ActivityDispatcher header_fields, Runner
# InitializeWorkflow headers).
sub to_payload_map ($payload_converter, $map) {
    return {
        map {
            my $v = $map->{$_};
            $_ => (is_payload($v) ? $v : $payload_converter->to_payload($v))
        } keys %$map
    };
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Interceptor::Headers - the shared header-representation contract

=head1 DESCRIPTION

One place for the rule that interceptor headers travel as C<< Str => Payload >>
maps in BOTH directions (#10 C-ICEPT-ACTIVITY-HEADERS), matching sdk-python's
C<Mapping[str, Payload]> header shape:

=over 4

=item * Outbound paths call L</to_payload_map> to encode a header map to the
wire, passing an already-Payload value through unchanged so it is never
double-encoded.

=item * Inbound paths thread the proto C<< Str => Payload >> header map
(C<header_fields> on an activity Start, C<headers> on an InitializeWorkflow job)
straight into the interceptor input, so the inbound hook reads pass-through
Payloads.

=back

=head1 FUNCTIONS

=head2 is_payload

C<< Temporalio::Interceptor::Headers::is_payload($value) >> returns true when
C<$value> is already a Temporal Payload (and so must be carried through a header
map as-is rather than re-encoded).

=head2 to_payload_map

C<< Temporalio::Interceptor::Headers::to_payload_map($payload_converter, \%map) >>
returns a new C<< { name => Payload } >> map: each value is passed through if it
is already a Payload, otherwise encoded once via C<< $payload_converter->to_payload >>.

=cut
