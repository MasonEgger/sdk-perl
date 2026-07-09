# ABOUTME: Fake OpenTelemetry scaffold for t/unit/tracing.t (spec R22/R41/R42),
# ABOUTME: adapted from the step-45 verify-45/api-otel/fakeotel probe: a recording
# ABOUTME: tracer/span plus a deterministic propagator mimicking the OpenTelemetry
# ABOUTME: Perl API subset the TracingInterceptor drives (create_span/set_status/
# ABOUTME: record_exception/end + inject/extract). Headless: no OTel dependency.
use v5.38;
use warnings;

# --- FakeOTel::Context ------------------------------------------------------
# The opaque "context" the propagator produces/consumes: a bag holding a W3C
# carrier (Str => Str). The real analogue is OpenTelemetry::Context.
package FakeOTel::Context;

sub new ($class, %a) { bless { carrier => $a{carrier} // {} }, $class }
sub carrier ($self) { $self->{carrier} }

# --- FakeOTel::Span ---------------------------------------------------------
# Records everything the interceptor does to it. `context` returns a
# FakeOTel::Context whose traceparent embeds the span id, so tests can assert
# the inject side round-trips this exact span.
package FakeOTel::Span;

my $NEXT_ID = 0;

sub new ($class, %a) {
    my $id = sprintf '%016x', ++$NEXT_ID;
    return bless {
        name               => $a{name},
        kind               => $a{kind},
        attributes         => $a{attributes} // {},
        parent             => $a{parent},
        links              => $a{links},
        start_timestamp    => $a{start_timestamp},
        span_id            => $id,
        status             => undef,
        status_description => undef,
        exceptions         => [],
        ended              => 0,
        end_timestamp      => undef,
    }, $class;
}

sub name            ($self) { $self->{name} }
sub kind            ($self) { $self->{kind} }
sub attributes      ($self) { $self->{attributes} }
sub parent          ($self) { $self->{parent} }
sub links           ($self) { $self->{links} }
sub start_timestamp ($self) { $self->{start_timestamp} }
sub span_id         ($self) { $self->{span_id} }
sub status          ($self) { $self->{status} }
sub status_description ($self) { $self->{status_description} }
sub exceptions      ($self) { $self->{exceptions} }
sub ended           ($self) { $self->{ended} }
sub end_timestamp   ($self) { $self->{end_timestamp} }

sub traceparent ($self) {
    return '00-' . ('f' x 16) . $self->{span_id} . "-$self->{span_id}-01";
}

sub context ($self) {
    return FakeOTel::Context->new(
        carrier => { traceparent => $self->traceparent });
}

sub set_status ($self, $status, $description = undef) {
    $self->{status}             = $status;
    $self->{status_description} = $description;
    return;
}

sub record_exception ($self, $exception) {
    push @{ $self->{exceptions} }, $exception;
    return;
}

sub end ($self, $timestamp = undef) {
    $self->{ended}         = 1;
    $self->{end_timestamp} = $timestamp;
    return;
}

# --- FakeOTel::Tracer -------------------------------------------------------
package FakeOTel::Tracer;

sub new ($class) { bless { spans => [] }, $class }
sub spans ($self) { $self->{spans} }

sub create_span ($self, %a) {
    my $span = FakeOTel::Span->new(%a);
    push @{ $self->{spans} }, $span;
    return $span;
}

# Test convenience: spans matching a name.
sub spans_named ($self, $name) {
    return [ grep { $_->name eq $name } @{ $self->{spans} } ];
}

# --- FakeOTel::Propagator ---------------------------------------------------
# inject($carrier, $context) copies the context's carrier keys into $carrier;
# extract($carrier) wraps a copy of the carrier in a FakeOTel::Context. The
# 2-arg call shape matches the real OpenTelemetry::Propagator::* interface.
package FakeOTel::Propagator;

sub new ($class) { bless {}, $class }

sub inject ($self, $carrier, $context = undef, @) {
    return unless defined $context
        && Scalar::Util::blessed($context)
        && $context->isa('FakeOTel::Context');
    %$carrier = (%$carrier, %{ $context->carrier });
    return;
}

sub extract ($self, $carrier, @) {
    return FakeOTel::Context->new(carrier => { %{ $carrier // {} } });
}

package FakeOTel;

use Scalar::Util ();

1;
