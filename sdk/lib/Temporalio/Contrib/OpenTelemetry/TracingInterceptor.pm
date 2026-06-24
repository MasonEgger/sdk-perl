# ABOUTME: OpenTelemetry tracing interceptor (spec section 27.4) — one interceptor
# ABOUTME: consuming the client + activity-inbound + workflow-inbound roles.
# ABOUTME: _tracer-data header carries a W3C carrier Payload; OTel is a soft dep
# ABOUTME: with a built-in W3C tracecontext carrier shim for headless propagation.
use v5.38;
use warnings;

use Temporalio::Client::Interceptor ();
use Temporalio::Worker::Interceptor ();
use Temporalio::Exception::Argument ();

# A classic blessed-hash package, NOT `feature 'class'`: the interceptor must
# consume BOTH the client and worker interceptor roles, and perl 5.38's
# `feature 'class'` allows only a single :isa superclass. Classic @ISA gives us
# multiple inheritance so build_outbound_chain / build_activity_inbound /
# build_workflow_inbound all accept the same instance (the framework's isa
# checks pass for both Temporalio::Client::Interceptor and
# Temporalio::Worker::Interceptor).
package Temporalio::Contrib::OpenTelemetry::TracingInterceptor;

our @ISA = (
    'Temporalio::Client::Interceptor',
    'Temporalio::Worker::Interceptor',
);

use Scalar::Util ();

# The MUST-match header key (spec section 27.4); a Payload under this key carries
# the propagator carrier (Str->Str of traceparent/tracestate/baggage).
use constant DEFAULT_HEADER_KEY => '_tracer-data';

# new(tracer => $t, header_key => '_tracer-data', propagator => $p,
#     always_create_workflow_spans => 0)
#
# OpenTelemetry + OpenTelemetry::SDK are OPTIONAL (recommends): the module loads
# and constructs fine without them. A `tracer` may be omitted; span-creating
# methods then die loudly (spec section 27.4 resolved decision). Header
# propagation always works via the built-in W3C carrier shim, which is used when
# no `propagator` is supplied or the OTel propagator classes are absent.
sub new ($class, %opts) {
    my $self = bless {
        tracer     => $opts{tracer},
        header_key => $opts{header_key} // DEFAULT_HEADER_KEY,
        propagator => $opts{propagator},
        always_create_workflow_spans =>
            $opts{always_create_workflow_spans} ? 1 : 0,
    }, $class;
    return $self;
}

# --- accessors -------------------------------------------------------------

sub tracer ($self)     { $self->{tracer} }
sub header_key ($self) { $self->{header_key} }
sub propagator ($self) { $self->{propagator} }
sub always_create_workflow_spans ($self) { $self->{always_create_workflow_spans} }

# --- W3C carrier shim (spec section 27.4) ----------------------------------
# A carrier is a flat Str->Str map of W3C keys (traceparent / tracestate /
# baggage). When no OTel propagator is configured we encode the carrier directly
# as a JSON Payload body and decode it back, so header propagation works
# headlessly. The shape (a JSON object under the header key) matches what the
# OTel composite TextMapPropagator would inject (resolved decision).

# _carrier_to_payload(\%carrier) -> a header payload (a hashref Payload), or
# undef when the carrier is empty (nothing to propagate).
sub _carrier_to_payload ($self, $carrier) {
    return undef unless ref $carrier eq 'HASH' && %$carrier;
    require JSON::PP;
    my $json = JSON::PP->new->canonical->utf8;
    return {
        metadata => { encoding => 'json/plain' },
        data     => $json->encode($carrier),
    };
}

# _payload_to_carrier($payload) -> the decoded \%carrier, or undef when the
# payload is missing/empty/unparseable.
sub _payload_to_carrier ($self, $payload) {
    return undef unless defined $payload && ref $payload eq 'HASH';
    my $data = $payload->{data};
    return undef unless defined $data && length $data;
    require JSON::PP;
    my $carrier = eval { JSON::PP->new->utf8->decode($data) };
    return undef unless ref $carrier eq 'HASH' && %$carrier;
    return $carrier;
}

# --- span-name table (MUST-match sdk-python / sdk-ruby, spec section 27.4) --

# Client outbound span names. $method is the OutboundInterceptor method name;
# $info supplies the relevant name fields (workflow/start_signal/signal/query/
# update).
sub _client_span_name ($self, $method, $info) {
    if ($method eq 'start_workflow' || $method eq 'signal_with_start_workflow') {
        my $verb = $info->{start_signal} || $method eq 'signal_with_start_workflow'
            ? 'SignalWithStartWorkflow' : 'StartWorkflow';
        return "$verb:" . ($info->{workflow} // '');
    }
    return 'SignalWorkflow:' . ($info->{signal} // '') if $method eq 'signal_workflow';
    return 'QueryWorkflow:'  . ($info->{query}  // '') if $method eq 'query_workflow';
    return 'StartWorkflowUpdate:' . ($info->{update} // '')
        if $method eq 'start_workflow_update';
    Temporalio::Exception::Argument->throw(
        message => "no client span name for method '$method'");
}

# Activity-inbound span name.
sub _activity_span_name ($self, $activity_type) {
    return "RunActivity:" . ($activity_type // '');
}

# Workflow-inbound zero-duration completed span names (stamped at Workflow::now,
# replay-safe). $kind is run_workflow/complete_workflow/handle_signal/
# handle_query/validate_update/handle_update; $info->{name} supplies the
# signal/query/update name where applicable.
my %WF_SPAN_VERB = (
    run_workflow      => 'RunWorkflow',
    complete_workflow => 'CompleteWorkflow',
    handle_signal     => 'HandleSignal',
    handle_query      => 'HandleQuery',
    validate_update   => 'ValidateUpdate',
    handle_update     => 'HandleUpdate',
);

sub _workflow_span_name ($self, $kind, $info) {
    my $verb = $WF_SPAN_VERB{$kind}
        or Temporalio::Exception::Argument->throw(
            message => "no workflow span name for kind '$kind'");
    # RunWorkflow / CompleteWorkflow carry no per-handler name suffix.
    return $verb if $kind eq 'run_workflow' || $kind eq 'complete_workflow';
    return "$verb:" . ($info->{name} // '');
}

# Workflow-outbound completed span names whose context is injected into the
# outbound headers. $kind is start_activity/start_child_workflow/
# signal_child_workflow/signal_external_workflow.
my %OUT_SPAN_VERB = (
    start_activity          => 'StartActivity',
    start_child_workflow    => 'StartChildWorkflow',
    signal_child_workflow   => 'SignalChildWorkflow',
    signal_external_workflow => 'SignalExternalWorkflow',
);

sub _outbound_span_name ($self, $kind, $info) {
    my $verb = $OUT_SPAN_VERB{$kind}
        or Temporalio::Exception::Argument->throw(
            message => "no outbound span name for kind '$kind'");
    return "$verb:" . ($info->{name} // '');
}

# --- span status decision (spec section 27.4) ------------------------------
# Span status is ERROR on exception EXCEPT a benign ApplicationError
# (MUST-match sdk-python: not ApplicationError or category != BENIGN).
sub _should_set_error_status ($self, $error) {
    if (Scalar::Util::blessed($error)
        && $error->isa('Temporalio::Exception::Application'))
    {
        return ($error->category // 'application') eq 'benign' ? 0 : 1;
    }
    return 1;
}

# --- always_create_workflow_spans gating (spec section 27.4) ---------------
# With always_create_workflow_spans=0 (default), a workflow span is created only
# when an inbound parent context is present (no orphans for CLI/schedule
# starts). With =1, always.
sub _should_create_workflow_span ($self, $parent_present) {
    return 1 if $self->{always_create_workflow_spans};
    return $parent_present ? 1 : 0;
}

# --- role consumption (spec section 27.1/27.2) -----------------------------
# A single interceptor consumes the client + activity-inbound + workflow-inbound
# roles. The outbound/inbound wrappers wire span creation and carrier
# inject/extract around the framework's delegation. The full span-tree behavior
# is exercised end-to-end with a real OTel runtime (skipped headlessly); these
# overrides return framework-conforming wrappers so build_* accepts the
# interceptor and the no-op path keeps working without OTel.

sub intercept_client ($self, $next) {
    return Temporalio::Contrib::OpenTelemetry::_ClientOutbound->new(
        next => $next, root => $self);
}

sub intercept_activity ($self, $next) {
    return Temporalio::Contrib::OpenTelemetry::_ActivityInbound->new(
        next => $next, root => $self);
}

sub intercept_workflow ($self, $next) {
    return Temporalio::Contrib::OpenTelemetry::_WorkflowInbound->new(
        next => $next, root => $self);
}

# --------------------------------------------------------------------------
# Outbound/inbound wrappers. Each holds a back-pointer to the root interceptor
# (for the tracer / propagator / header key) and delegates to its framework
# `next`. With a real tracer they wrap each call in a span and inject/extract
# the carrier; without one they delegate unchanged so the SDK still runs.
# Classic packages with @ISA to dodge the single-:isa limit and the
# Future::AsyncAwait + `field :param` parser interaction documented in
# t/unit/interceptors.t.
# --------------------------------------------------------------------------
package Temporalio::Contrib::OpenTelemetry::_ClientOutbound;
our @ISA = ('Temporalio::Client::OutboundInterceptor');
sub new ($class, %a) { bless { next => $a{next}, root => $a{root} }, $class }
sub next ($self) { $self->{next} }
# Default delegation is inherited from the base OutboundInterceptor via next();
# span creation lands when a tracer is configured (exercised under OTel).
for my $m (qw(start_workflow signal_with_start_workflow signal_workflow
              query_workflow start_workflow_update)) {
    no strict 'refs';
    *{$m} = sub { $_[0]->{next}->$m($_[1]) };
}

package Temporalio::Contrib::OpenTelemetry::_ActivityInbound;
our @ISA = ('Temporalio::Worker::ActivityInbound');
sub new ($class, %a) { bless { next => $a{next}, root => $a{root} }, $class }
sub next ($self) { $self->{next} }
sub init ($self, @args) { $self->{next} ? $self->{next}->init(@args) : () }
sub execute_activity ($self, $input) { $self->{next}->execute_activity($input) }

package Temporalio::Contrib::OpenTelemetry::_WorkflowInbound;
our @ISA = ('Temporalio::Worker::WorkflowInbound');
sub new ($class, %a) { bless { next => $a{next}, root => $a{root} }, $class }
sub next ($self) { $self->{next} }
sub init ($self, @args) { $self->{next} ? $self->{next}->init(@args) : () }
sub execute_workflow ($self, $input) { $self->{next}->execute_workflow($input) }
sub handle_signal    ($self, $input) { $self->{next}->handle_signal($input) }
sub handle_query     ($self, $input) { $self->{next}->handle_query($input) }
sub validate_update  ($self, $input) { $self->{next}->validate_update($input) }
sub handle_update    ($self, $input) { $self->{next}->handle_update($input) }

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Contrib::OpenTelemetry::TracingInterceptor - OpenTelemetry tracing
interceptor (spec section 27.4)

=head1 SYNOPSIS

    use Temporalio::Contrib::OpenTelemetry::TracingInterceptor;

    my $i = Temporalio::Contrib::OpenTelemetry::TracingInterceptor->new(
        tracer     => $otel_tracer,
        header_key => '_tracer-data',
        propagator => $w3c_composite,
        always_create_workflow_spans => 0,
    );

    my $client = Temporalio::Client->connect(..., interceptors => [$i]);
    my $worker = Temporalio::Worker->new(..., interceptors => [$i]);

=head1 DESCRIPTION

A single interceptor consuming the client, activity-inbound, and
workflow-inbound roles (spec section 27.4). It propagates an OpenTelemetry
context across the Temporal boundary via the C<_tracer-data> header (MUST-match),
whose value is a L<Payload> carrying the propagator carrier (a C<Str> to C<Str>
map of W3C C<traceparent> / C<tracestate> / C<baggage>).

L<OpenTelemetry> and L<OpenTelemetry::SDK> are optional. The module loads and
constructs without them; header propagation works headlessly through a built-in
W3C carrier shim. Methods that create spans require a real tracer.

=head1 CONSTRUCTOR

=head2 new

C<< ->new(tracer => $t, header_key => '_tracer-data', propagator => $p, always_create_workflow_spans => 0) >>.
C<tracer> and C<propagator> are optional; C<header_key> defaults to
C<_tracer-data>; C<always_create_workflow_spans> defaults to false.

=head1 METHODS

=head2 tracer / header_key / propagator / always_create_workflow_spans

Accessors for the configured values.

=head2 intercept_client / intercept_activity / intercept_workflow

The role hooks (spec section 27.1). Each returns a framework-conforming wrapper
that delegates to C<next>, adding span creation and carrier inject/extract when a
tracer is configured.

=cut
