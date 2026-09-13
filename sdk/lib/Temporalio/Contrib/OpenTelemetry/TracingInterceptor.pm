# ABOUTME: OpenTelemetry tracing interceptor (spec R22, v1 spec section 27.4) —
# ABOUTME: one interceptor consuming the client + activity-inbound + workflow-inbound
# ABOUTME: roles: spans per intercepted surface, trace context injected outbound /
# ABOUTME: extracted inbound through the _tracer-data header (a W3C carrier Payload).
# ABOUTME: OTel is a soft dep; span/header semantics MUST-match sdk-python contrib.
use v5.38;
use warnings;

use Future ();
use Temporalio::Client::Interceptor ();
use Temporalio::Worker::Interceptor ();
use Temporalio::Workflow ();
use Temporalio::Workflow::Unsafe ();
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
# and constructs fine without them. When `tracer` is not passed at all, it
# defaults to a real OTel tracer if OpenTelemetry is installed (sdk-python
# parity: TracingInterceptor.__init__ defaults to opentelemetry.trace
# .get_tracer — the R42 fix) and to undef otherwise. Passing `tracer => undef`
# explicitly forces the headless no-span mode. Without a tracer every wrapper
# delegates unchanged; with one, spans are created per intercepted surface and
# trace context flows through the `_tracer-data` header.
sub new ($class, %opts) {
    my $self = bless {
        tracer     => (exists $opts{tracer}
            ? $opts{tracer} : $class->_default_tracer),
        header_key => $opts{header_key} // DEFAULT_HEADER_KEY,
        propagator => $opts{propagator},
        always_create_workflow_spans =>
            $opts{always_create_workflow_spans} ? 1 : 0,
    }, $class;
    return $self;
}

# _default_tracer — a real OTel tracer when OpenTelemetry is installed (the
# API-level tracer_provider; a no-op unless the process configured the SDK),
# undef otherwise. Finding T4 / R42: the previous constructor left tracer
# undef even with OpenTelemetry present, so the OTel-gated test failed.
sub _default_tracer ($class) {
    return undef unless eval { require OpenTelemetry; 1 };
    return scalar eval {
        OpenTelemetry->tracer_provider->tracer(name => 'temporalio-sdk-perl');
    };
}

# --- accessors -------------------------------------------------------------

sub tracer ($self)     { $self->{tracer} }
sub header_key ($self) { $self->{header_key} }
sub propagator ($self) { $self->{propagator} }
sub always_create_workflow_spans ($self) { $self->{always_create_workflow_spans} }

# --- W3C carrier shim (spec section 27.4) ----------------------------------
# A carrier is a flat Str->Str map of W3C keys (traceparent / tracestate /
# baggage). The shim encodes the carrier as a JSON Payload body and decodes it
# back — the same json/plain shape sdk-python writes via
# PayloadConverter.to_payloads([carrier]) (_interceptor.py:147-172).

# _carrier_to_payload(\%carrier) -> a BLESSED header Payload, or undef when
# the carrier is empty (nothing to propagate). This is the ONE header-payload
# builder: the client outbound side and the workflow outbound side both reach
# it through _inject_headers below, so there is a single answer to "what shape
# is a _tracer-data header value".
#
# The blessing is load-bearing (spec F1, GitHub #6). Every
# outbound header map is encoded to the wire by
# Temporalio::Interceptor::Headers::to_payload_map, whose is_payload test is
# `blessed && isa(temporal.api.common.v1.Payload)`. An unblessed
# { metadata, data } hashref fails that test, so the JSON converter encodes
# the WHOLE hashref as a payload body and the receiver needs two decodes to
# reach the carrier (the double-encode class lessons.md 2026-06-26 records).
# Temporalio::Payload IS the generated Payload class under a stable name, so a
# value built here passes is_payload and rides through untouched. sdk-python
# builds the same thing with payload_converter.to_payloads([carrier])[0]
# (contrib/opentelemetry/_interceptor.py:675-682), and its header type is
# Mapping[str, Payload] on both the inbound and outbound sides.
#
# The require is lazy on purpose: loading Temporalio::Payload triggers the
# one-time vendored-proto parse, and this module is otherwise cheap to load.
sub _carrier_to_payload ($self, $carrier) {
    return undef unless ref $carrier eq 'HASH' && %$carrier;
    require JSON::PP;
    require Temporalio::Payload;
    my $json = JSON::PP->new->canonical->utf8;
    return Temporalio::Payload->new({
        metadata => { encoding => 'json/plain' },
        data     => $json->encode($carrier),
    });
}

# _payload_to_carrier($payload) -> the decoded \%carrier, or undef when the
# payload is missing/empty/unparseable.
#
# DUCK-TYPED on the metadata/data accessors rather than matched against one
# representation (spec F1). Payloads reaching the inbound side come off the
# wire inside other messages (the activity Start task's header_fields, threaded
# by Worker/ActivityDispatcher.pm; the InitializeWorkflow job's headers,
# threaded by Workflow/Runner.pm _apply_initialize), and those are instances of
# the GENERATED parent class, not of Temporalio::Payload. Payload.pm's POD
# states the rule: consumers duck-type. The unblessed { metadata, data }
# hashref is still accepted so a hand-built test fixture or an older
# interceptor's header value keeps decoding.
sub _payload_to_carrier ($self, $payload) {
    return undef unless defined $payload;
    my $data;
    if (Scalar::Util::blessed($payload)) {
        return undef unless $payload->can('metadata') && $payload->can('data');
        $data = $payload->data;
    }
    elsif (ref $payload eq 'HASH') {
        $data = $payload->{data};
    }
    return undef unless defined $data && length $data;
    require JSON::PP;
    my $carrier = eval { JSON::PP->new->utf8->decode($data) };
    return undef unless ref $carrier eq 'HASH' && %$carrier;
    return $carrier;
}

# --- span-name table (MUST-match sdk-python / sdk-ruby, spec section 27.4) --

# Client outbound span names. $method is the OutboundInterceptor method name;
# $info supplies the relevant name fields (workflow/start_signal/signal/query/
# update). MUST-match sdk-python contrib/opentelemetry/_interceptor.py:275-318.
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

# Activity-inbound span name (_interceptor.py:378).
sub _activity_span_name ($self, $activity_type) {
    return "RunActivity:" . ($activity_type // '');
}

# Workflow-inbound zero-duration completed span names (stamped at workflow
# time, replay-safe). $kind is run_workflow/complete_workflow/handle_signal/
# handle_query/validate_update/handle_update; $info->{name} supplies the
# workflow-type/signal/query/update name. Every verb carries the name suffix:
# sdk-python writes RunWorkflow:{type} (_interceptor.py:507) and
# CompleteWorkflow:{type} (:656); sdk-ruby open_telemetry.rb:247/:251 agree.
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
    return "$verb:" . ($info->{name} // '');
}

# Workflow-outbound completed span names whose context is injected into the
# outbound headers (_interceptor.py:767-831; spec I6, closes GitHub #6).
# $kind is start_activity/start_child_workflow/signal_child_workflow/
# signal_external_workflow/start_nexus_operation. execute_local_activity
# reuses the start_activity verb (Python start_local_activity:811-820); the
# wrapper is Temporalio::Contrib::OpenTelemetry::_WorkflowOutbound below,
# installed by _WorkflowInbound::init on the R71 chain.
my %OUT_SPAN_VERB = (
    start_activity           => 'StartActivity',
    start_child_workflow     => 'StartChildWorkflow',
    signal_child_workflow    => 'SignalChildWorkflow',
    signal_external_workflow => 'SignalExternalWorkflow',
    start_nexus_operation    => 'StartNexusOperation',
);

sub _outbound_span_name ($self, $kind, $info) {
    my $verb = $OUT_SPAN_VERB{$kind}
        or Temporalio::Exception::Argument->throw(
            message => "no outbound span name for kind '$kind'");
    return "$verb:" . ($info->{name} // '');
}

# --- span status decision (spec section 27.4) ------------------------------
# Span status is ERROR on exception EXCEPT a benign ApplicationError
# (MUST-match sdk-python: not ApplicationError or category != BENIGN,
# _interceptor.py:209-220).
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

# --- tracer/propagator adaptation ------------------------------------------
# The interceptor drives a small duck-typed surface — create_span(name/kind/
# attributes/parent/links/start_timestamp), span set_status/record_exception/
# end, propagator inject/extract — that both the real OpenTelemetry Perl API
# and the test fake satisfy. When the tracer IS the real thing, kinds and
# status codes are mapped to the OpenTelemetry::Constants values and the
# default W3C composite propagator is used; otherwise plain strings flow
# through so a fake tracer sees 'client'/'server'/'internal' and 'error'.

sub _tracer_is_otel ($self) {
    return Scalar::Util::blessed($self->{tracer})
        && $self->{tracer}->isa('OpenTelemetry::Trace::Tracer') ? 1 : 0;
}

my %OTEL_KIND_CONST = (
    client   => 'SPAN_KIND_CLIENT',
    server   => 'SPAN_KIND_SERVER',
    internal => 'SPAN_KIND_INTERNAL',
);

sub _span_kind ($self, $kind) {
    if ($self->_tracer_is_otel
        && eval { require OpenTelemetry::Constants; 1 })
    {
        my $const = OpenTelemetry::Constants->can($OTEL_KIND_CONST{$kind} // '');
        return $const->() if $const;
    }
    return $kind;
}

sub _error_status_code ($self) {
    if ($self->_tracer_is_otel
        && eval { require OpenTelemetry::Constants; 1 })
    {
        my $const = OpenTelemetry::Constants->can('SPAN_STATUS_ERROR');
        return $const->() if $const;
    }
    return 'error';
}

# _context_for_span($span) -> a propagator-injectable context carrying the
# span: OpenTelemetry::Trace->context_with_span for a real span, the span's
# own ->context otherwise (the fake-tracer contract).
sub _context_for_span ($self, $span) {
    if (Scalar::Util::blessed($span)
        && $span->isa('OpenTelemetry::Trace::Span')
        && eval { require OpenTelemetry::Trace; 1 })
    {
        return OpenTelemetry::Trace->context_with_span($span);
    }
    return $span->can('context') ? $span->context : undef;
}

# _effective_propagator — the configured propagator, or (for a real OTel
# tracer) the default W3C TraceContext + Baggage composite (sdk-python
# default_text_map_propagator parity, _interceptor.py:48-53), or undef.
# Without a propagator the inject side has no way to render a context, so no
# header is written; the extract side falls back to handing the raw carrier
# hashref to create_span as the parent (headless mode).
sub _effective_propagator ($self) {
    return $self->{propagator} if defined $self->{propagator};
    return $self->{_default_propagator} if exists $self->{_default_propagator};
    my $prop;
    if ($self->_tracer_is_otel) {
        $prop = eval {
            require OpenTelemetry::Propagator::TraceContext;
            my @p = (OpenTelemetry::Propagator::TraceContext->new);
            push @p, OpenTelemetry::Propagator::Baggage->new
                if eval { require OpenTelemetry::Propagator::Baggage; 1 };
            @p > 1 && eval { require OpenTelemetry::Propagator::Composite; 1 }
                ? OpenTelemetry::Propagator::Composite->new(@p)
                : $p[0];
        };
    }
    return $self->{_default_propagator} = $prop;
}

# _carrier_from_context($context) -> the rendered \%carrier, or undef when
# there is no propagator, the injection dies, or the context renders nothing
# (a non-recording span, or an absent context with a propagator that needs
# one). The single rendering step behind BOTH injection shapes: the
# _tracer-data Payload header (_inject_headers below, used by the client
# outbound and workflow outbound sides alike) and the plain Str => Str nexus
# header map (_WorkflowOutbound::_inject_str_headers). Injection failures
# degrade to no header rather than failing the intercepted call.
sub _carrier_from_context ($self, $context) {
    my $prop = $self->_effective_propagator or return undef;
    my %carrier;
    eval {
        defined $context
            ? $prop->inject(\%carrier, $context)
            : $prop->inject(\%carrier);
        1;
    } or return undef;
    return %carrier ? \%carrier : undef;
}

# _inject_headers(\%headers, $context) -> a NEW header map with the context
# rendered into a carrier Payload under header_key, or the input map unchanged
# when there is nothing to inject. A header already sitting under header_key is
# REPLACED, never duplicated or merged: the value must describe the span this
# call created, not whatever context arrived from somewhere above.
sub _inject_headers ($self, $headers, $context) {
    my $carrier = $self->_carrier_from_context($context)
        or return $headers // {};
    my $payload = $self->_carrier_to_payload($carrier)
        or return $headers // {};
    return { %{ $headers // {} }, $self->{header_key} => $payload };
}

# _context_from_headers(\%headers) -> the extracted context, or undef when no
# _tracer-data header is present.
sub _context_from_headers ($self, $headers) {
    my $carrier = $self->_payload_to_carrier(
        ($headers // {})->{ $self->{header_key} });
    return undef unless $carrier;
    return $self->_carrier_to_context($carrier);
}

# _carrier_to_context(\%carrier) -> a context via the propagator, or the raw
# carrier hashref headlessly.
sub _carrier_to_context ($self, $carrier) {
    my $prop = $self->_effective_propagator or return $carrier;
    my $ctx = eval { $prop->extract($carrier) };
    return $ctx // $carrier;
}

# _links_from_carrier(\%carrier) -> an arrayref of span links for create_span,
# or undef. Real tracer: [{ context => $span_context }] when the carrier
# yields a valid span context; fake: the extracted context itself.
sub _links_from_carrier ($self, $carrier) {
    return undef unless ref $carrier eq 'HASH' && %$carrier;
    my $ctx = $self->_carrier_to_context($carrier);
    return undef unless defined $ctx;
    if ($self->_tracer_is_otel) {
        my $link = eval {
            my $span = OpenTelemetry::Trace->span_from_context($ctx);
            my $sc   = $span->context;
            $sc->valid ? { context => $sc } : undef;
        };
        return defined $link ? [$link] : undef;
    }
    return [$ctx];
}

# _finish_span($span, $ready_future) — set ERROR status for a failed call
# (except a benign ApplicationError) and end the span.
sub _finish_span ($self, $span, $done) {
    if ($done->is_ready && !$done->is_cancelled && $done->is_failed) {
        my ($error) = $done->failure;
        if ($self->_should_set_error_status($error)) {
            my $description = "$error";
            $description =~ s/\n+\z//;
            $span->set_status($self->_error_status_code, $description);
        }
    }
    $span->end;
    return;
}

# _wf_time / _wf_replaying / _wf_attributes — replay-safe workflow-context
# reads with out-of-workflow fallbacks (the unit tests drive the wrappers
# without a Runner; inside a run these resolve through $Runner::CURRENT).
sub _wf_time ($self) {
    my $t = eval { Temporalio::Workflow::time() };
    return $t if defined $t;
    require Time::HiRes;
    return Time::HiRes::time();
}

sub _wf_replaying ($self) {
    return eval { Temporalio::Workflow::is_replaying() } ? 1 : 0;
}

sub _wf_attributes ($self) {
    my $info = eval { Temporalio::Workflow::info() } // {};
    my %attrs;
    $attrs{temporalWorkflowID} = $info->{workflow_id}
        if defined $info->{workflow_id};
    $attrs{temporalRunID} = $info->{run_id} if defined $info->{run_id};
    return %attrs;
}

# --- role consumption (spec section 27.1/27.2) -----------------------------
# A single interceptor consumes the client + activity-inbound + workflow-inbound
# roles. Each wrapper holds a back-pointer to this root (for the tracer /
# propagator / header key); without a tracer every wrapper delegates unchanged
# so the SDK still runs headlessly.

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
# Outbound/inbound wrappers (finding R1 / spec R22: previously these were pure
# delegation while the POD claimed spans + propagation; they now implement
# both, matching sdk-python contrib/opentelemetry/_interceptor.py). Classic
# packages with @ISA to dodge the single-:isa limit and the Future::AsyncAwait
# + `field :param` parser interaction documented in t/unit/interceptors.t.
# --------------------------------------------------------------------------

# Client outbound: one CLIENT-kind span per call, named from the MUST-match
# table, with the new span's context injected into the outbound headers under
# header_key (Python _TracingClientOutboundInterceptor:268-356).
package Temporalio::Contrib::OpenTelemetry::_ClientOutbound;
our @ISA = ('Temporalio::Client::OutboundInterceptor');
sub new ($class, %a) { bless { next => $a{next}, root => $a{root} }, $class }
sub next ($self) { $self->{next} }

# Per-method surface description: how to read the span-name fields and the
# workflow id, and where the headers live. signal_with_start_workflow has no
# top-level Input headers (spec section 27.1) — the context goes into the
# embedded start op's kwargs headers, which the root RPC builder consumes.
my %CLIENT_SURFACE = (
    start_workflow => {
        info    => sub ($in) { { workflow => $in->get('workflow') } },
        id      => sub ($in) { ($in->get('kwargs') // {})->{id} },
        headers => 'input',
    },
    signal_with_start_workflow => {
        info    => sub ($in) { { workflow => $in->get('workflow') } },
        id      => sub ($in) { ($in->get('kwargs') // {})->{id} },
        headers => 'kwargs',
    },
    signal_workflow => {
        info    => sub ($in) { { signal => $in->get('signal') } },
        id      => sub ($in) { $in->get('id') },
        headers => 'input',
    },
    query_workflow => {
        info    => sub ($in) { { query => $in->get('query') } },
        id      => sub ($in) { $in->get('id') },
        headers => 'input',
    },
    start_workflow_update => {
        info    => sub ($in) { { update => $in->get('update') } },
        id      => sub ($in) { $in->get('id') },
        headers => 'input',
    },
);

for my $m (sort keys %CLIENT_SURFACE) {
    my $surface = $CLIENT_SURFACE{$m};
    no strict 'refs';
    *{$m} = sub ($self, $input) {
        my $root = $self->{root};
        my $next = $self->{next};
        return $next->$m($input) unless $root->tracer;

        my $id   = $surface->{id}->($input);
        my $span = $root->tracer->create_span(
            name       => $root->_client_span_name($m, $surface->{info}->($input)),
            kind       => $root->_span_kind('client'),
            attributes => { defined $id ? (temporalWorkflowID => $id) : () },
        );
        my $context = $root->_context_for_span($span);
        if ($surface->{headers} eq 'kwargs') {
            my $kwargs = $input->get('kwargs') // {};
            $kwargs->{headers} =
                $root->_inject_headers($kwargs->{headers}, $context);
        }
        else {
            $input->headers($root->_inject_headers($input->headers, $context));
        }
        # Future->call + Future->wrap: a sync die becomes a failed Future and a
        # plain return a done one (lessons.md 2026-06-13); on_ready returns the
        # same Future so the caller sees the unmodified result/failure.
        my $f = Future->call(sub { Future->wrap($next->$m($input)) });
        return $f->on_ready(sub ($done) { $root->_finish_span($span, $done) });
    };
}

# Activity inbound: one SERVER-kind RunActivity span per execution, parented
# on the context EXTRACTED from the inbound _tracer-data header (Python
# _TracingActivityInboundInterceptor:359-383). The activity type and id
# attributes come from the `info` field the ActivityDispatcher threads onto
# the ExecuteActivity input.
package Temporalio::Contrib::OpenTelemetry::_ActivityInbound;
our @ISA = ('Temporalio::Worker::ActivityInbound');
sub new ($class, %a) { bless { next => $a{next}, root => $a{root} }, $class }
sub next ($self) { $self->{next} }
sub init ($self, @args) { $self->{next} ? $self->{next}->init(@args) : () }

sub execute_activity ($self, $input) {
    my $root = $self->{root};
    my $next = $self->{next};
    return $next->execute_activity($input) unless $root->tracer;

    my $info = $input->get('info') // {};
    my %attrs;
    $attrs{temporalActivityID} = $info->{activity_id}
        if defined $info->{activity_id};
    $attrs{temporalWorkflowID} = $info->{workflow_id}
        if defined $info->{workflow_id};
    $attrs{temporalRunID} = $info->{workflow_run_id}
        if defined $info->{workflow_run_id};

    my $parent = $root->_context_from_headers($input->headers);
    my $span   = $root->tracer->create_span(
        name       => $root->_activity_span_name($info->{activity_type}),
        kind       => $root->_span_kind('server'),
        attributes => \%attrs,
        (defined $parent ? (parent => $parent) : ()),
    );
    my $f = Future->call(sub { Future->wrap($next->execute_activity($input)) });
    return $f->on_ready(sub ($done) { $root->_finish_span($span, $done) });
}

# Workflow inbound: zero-duration completed spans stamped at workflow time —
# it is not replay-safe to keep an unended span across activations (Python
# _completed_workflow_span:225-265) — skipped while replaying (except query
# spans) and gated on an inbound parent context unless
# always_create_workflow_spans. Every span in a run is parented on the
# ORIGINAL start-header context, cached at execute_workflow (Python caches
# _workflow_context_carrier the same way, _interceptor.py:613-622).
package Temporalio::Contrib::OpenTelemetry::_WorkflowInbound;
our @ISA = ('Temporalio::Worker::WorkflowInbound');
sub new ($class, %a) { bless { next => $a{next}, root => $a{root} }, $class }
sub next ($self) { $self->{next} }

# init RECEIVES the real workflow outbound (spec R71 wired the chain: the
# Runner calls inbound->init(outbound) and routes the outbound operations
# through whatever reaches the chain root). I6 (closes GitHub #6): wrap
# $args[0] in a _WorkflowOutbound that creates a completed span per
# execute_activity / execute_local_activity / start_child_workflow /
# signal_child_workflow / signal_external_workflow / start_nexus_operation
# (the %OUT_SPAN_VERB table above), injects the new context into the outbound
# input headers, and delegates the WRAPPED outbound down-chain, mirroring
# Python's _TracingWorkflowOutboundInterceptor:751-831. The wrapper holds a
# back-reference to $self (not just $root) so it can read the run's cached
# wf_carrier at call time (set by execute_workflow below, BEFORE the workflow
# body, and so any outbound call, runs).
sub init ($self, @args) {
    my $wrapped = Temporalio::Contrib::OpenTelemetry::_WorkflowOutbound->new(
        next => $args[0], root => $self->{root}, inbound => $self);
    return $self->{next} ? $self->{next}->init($wrapped) : ();
}

sub execute_workflow ($self, $input) {
    my $root = $self->{root};
    my $next = $self->{next};
    return $next->execute_workflow($input) unless $root->tracer;

    # Cache the run's inbound context carrier and type for the handler spans.
    $self->{wf_carrier} = $root->_payload_to_carrier(
        ($input->headers // {})->{ $root->header_key });
    $self->{wf_type} =
        (eval { Temporalio::Workflow::info() } // {})->{workflow_type}
        // $input->get('type') // '';

    $self->_completed_span(
        $root->_workflow_span_name(
            run_workflow => { name => $self->{wf_type} }),
        kind => 'server');

    my $f  = eval { $next->execute_workflow($input) };
    my $err = $@;
    if (!defined $f && $err) {
        $self->_complete_workflow_span($err);
        die $err;
    }
    if (Scalar::Util::blessed($f) && $f->can('on_ready')) {
        $f->on_ready(sub ($done) {
            return if $done->is_cancelled;
            if ($done->is_failed) {
                my ($failure) = $done->failure;
                $self->_complete_workflow_span($failure);
            }
            else {
                $self->_complete_workflow_span(undef);
            }
        });
    }
    return $f;
}

# CompleteWorkflow:{type} on completion. Python parity
# (_top_level_workflow_context:644-659): only workflow-COMPLETING failures
# (FailureError analogues — blessed Temporalio::Exception instances) get the
# span; a plain die is a task failure and the workflow is not complete.
sub _complete_workflow_span ($self, $exception) {
    if (defined $exception) {
        return unless Scalar::Util::blessed($exception)
            && $exception->isa('Temporalio::Exception');
    }
    my $root = $self->{root};
    $self->_completed_span(
        $root->_workflow_span_name(
            complete_workflow => { name => $self->{wf_type} }),
        kind      => 'internal',
        exception => $exception);
    return;
}

# Shared handler shape (signal / update-validate / update): a server-kind
# completed span parented on the workflow context, with the dispatch input's
# own _tracer-data header (the sender context) contributing a span LINK, not
# a parent (Python handle_signal:512-530 / handle_update_*:573-611).
sub _handler_completed_span ($self, $input, $verb_key, $name_field) {
    my $root = $self->{root};
    $self->_completed_span(
        $root->_workflow_span_name(
            $verb_key => { name => $input->get($name_field) }),
        kind         => 'server',
        link_carrier => $root->_payload_to_carrier(
            ($input->headers // {})->{ $root->header_key }));
    return;
}

sub handle_signal ($self, $input) {
    my $next = $self->{next};
    return $next->handle_signal($input) unless $self->{root}->tracer;
    $self->_handler_completed_span($input, handle_signal => 'signal');
    return $next->handle_signal($input);
}

# Query spans parent on the QUERY header context only — no span without one —
# link the workflow context, and are created even on replay (Python
# handle_query:532-571).
sub handle_query ($self, $input) {
    my $root = $self->{root};
    my $next = $self->{next};
    return $next->handle_query($input) unless $root->tracer;
    $self->_completed_span(
        $root->_workflow_span_name(
            handle_query => { name => $input->get('query') }),
        kind           => 'server',
        parent_carrier => $root->_payload_to_carrier(
            ($input->headers // {})->{ $root->header_key }),
        link_carrier   => $self->{wf_carrier},
        even_on_replay => 1);
    return $next->handle_query($input);
}

sub validate_update ($self, $input) {
    my $next = $self->{next};
    return $next->validate_update($input) unless $self->{root}->tracer;
    $self->_handler_completed_span($input, validate_update => 'update');
    return $next->validate_update($input);
}

sub handle_update ($self, $input) {
    my $next = $self->{next};
    return $next->handle_update($input) unless $self->{root}->tracer;
    $self->_handler_completed_span($input, handle_update => 'update');
    return $next->handle_update($input);
}

# _completed_span($name, kind =>, exception =>, link_carrier =>,
# parent_carrier =>, even_on_replay =>) — create-and-immediately-end a span
# stamped at workflow time. Skipped while replaying (unless even_on_replay)
# and gated on parent presence via _should_create_workflow_span. The parent
# defaults to the cached workflow carrier; passing parent_carrier (even undef)
# overrides it (the query rule). Span creation runs under
# durable_scheduler_disabled so tracer internals cannot record on / yield to
# the durable scheduler (v1 spec section 27.4 resolved decision).
sub _completed_span ($self, $name, %opt) {
    my $root = $self->{root};
    return unless $root->tracer;
    return if $root->_wf_replaying && !$opt{even_on_replay};
    my $carrier = exists $opt{parent_carrier}
        ? $opt{parent_carrier} : $self->{wf_carrier};
    return unless $root->_should_create_workflow_span($carrier ? 1 : 0);

    my $parent = defined $carrier
        ? $root->_carrier_to_context($carrier) : undef;
    my $links = $root->_links_from_carrier($opt{link_carrier});
    my $time  = $root->_wf_time;
    my %attrs = $root->_wf_attributes;

    Temporalio::Workflow::Unsafe::durable_scheduler_disabled(sub {
        my $span = $root->tracer->create_span(
            name            => $name,
            kind            => $root->_span_kind($opt{kind} // 'internal'),
            attributes      => \%attrs,
            start_timestamp => $time,
            (defined $parent ? (parent => $parent) : ()),
            (defined $links  ? (links  => $links)  : ()),
        );
        $span->record_exception($opt{exception})
            if defined $opt{exception} && $span->can('record_exception');
        $span->end($time);
        return $span;
    });
    return;
}

# Workflow outbound (spec I6, closes GitHub #6): a completed span per traced
# op (%OUT_SPAN_VERB above) with the NEW span's context injected into the
# op's outbound headers, mirroring Python's
# _TracingWorkflowOutboundInterceptor (contrib/opentelemetry/_interceptor.py
# :751-831). Installed by _WorkflowInbound::init above, which passes the
# inbound instance so this wrapper can read the run's cached wf_carrier at
# call time (the same parent every handler span above uses). Every traced op
# reuses the _WorkflowInbound::_completed_span replay/parent gate (skipped
# while replaying, gated on parent presence via _should_create_workflow_span)
# via the shared helper below; continue_as_new is the one exception (Python
# :762-765: header injection only, no span, no replay gate).
package Temporalio::Contrib::OpenTelemetry::_WorkflowOutbound;
our @ISA = ('Temporalio::Worker::WorkflowOutbound');
sub new ($class, %a) {
    bless { next => $a{next}, root => $a{root}, inbound => $a{inbound} }, $class;
}
sub next ($self) { $self->{next} }

# _traced_call($method, $input, $kind, $name, %opt): the REFACTOR sub-step 6
# helper: one span+inject call site per outbound op, keyed by the caller's
# $name (built from %OUT_SPAN_VERB). $opt{str_headers} routes the injection
# through the nexus_header Str=>Str shape (spec section 26.1) instead of a
# _tracer-data Payload.
sub _traced_call ($self, $method, $input, $kind, $name, %opt) {
    my $root = $self->{root};
    my $next = $self->{next};
    return $next->$method($input) unless $root->tracer;

    my $inbound = $self->{inbound};
    my $carrier = $inbound ? $inbound->{wf_carrier} : undef;
    if (!$root->_wf_replaying
        && $root->_should_create_workflow_span($carrier ? 1 : 0))
    {
        my $parent = defined $carrier
            ? $root->_carrier_to_context($carrier) : undef;
        my $time  = $root->_wf_time;
        my %attrs = $root->_wf_attributes;
        my $context;

        Temporalio::Workflow::Unsafe::durable_scheduler_disabled(sub {
            my $span = $root->tracer->create_span(
                name            => $name,
                kind            => $root->_span_kind($kind),
                attributes      => \%attrs,
                start_timestamp => $time,
                (defined $parent ? (parent => $parent) : ()),
            );
            $span->end($time);
            $context = $root->_context_for_span($span);
            return $span;
        });

        $input->headers(
            $opt{str_headers}
                ? $self->_inject_str_headers($input->headers, $context)
                : $root->_inject_headers($input->headers, $context));
    }
    return $next->$method($input);
}

# _inject_str_headers(\%headers, $context): the Nexus-header analogue of
# root's _inject_headers. Both render the context through the root's single
# _carrier_from_context helper; only the WRITE differs. This one merges the
# carrier's keys DIRECTLY into a plain Str=>Str map (Python
# _carrier_to_nexus_headers:834-843), never under header_key as a Payload
# (start_nexus_operation's headers travel to a possibly-external Nexus handler
# as nexus_header, spec section 26.1).
sub _inject_str_headers ($self, $headers, $context) {
    my $carrier = $self->{root}->_carrier_from_context($context)
        or return $headers // {};
    my %out = %{ $headers // {} };
    for my $k (keys %$carrier) {
        my $v = $carrier->{$k};
        $out{$k} = ref $v eq 'ARRAY' ? join(',', @$v) : $v;
    }
    return \%out;
}

sub execute_activity ($self, $input) {
    my $root = $self->{root};
    return $self->_traced_call('execute_activity', $input, 'client',
        $root->_outbound_span_name(
            start_activity => { name => $input->get('activity') }));
}

# execute_local_activity reuses the start_activity verb (Python
# start_local_activity:811-820: "StartActivity:{activity}", same as a normal
# activity).
sub execute_local_activity ($self, $input) {
    my $root = $self->{root};
    return $self->_traced_call('execute_local_activity', $input, 'client',
        $root->_outbound_span_name(
            start_activity => { name => $input->get('activity') }));
}

sub start_child_workflow ($self, $input) {
    my $root = $self->{root};
    return $self->_traced_call('start_child_workflow', $input, 'client',
        $root->_outbound_span_name(
            start_child_workflow => { name => $input->get('workflow') }));
}

# SERVER kind (Python :767-776), unlike the other outbound spans.
sub signal_child_workflow ($self, $input) {
    my $root = $self->{root};
    return $self->_traced_call('signal_child_workflow', $input, 'server',
        $root->_outbound_span_name(
            signal_child_workflow => { name => $input->get('signal') }));
}

sub signal_external_workflow ($self, $input) {
    my $root = $self->{root};
    return $self->_traced_call('signal_external_workflow', $input, 'client',
        $root->_outbound_span_name(
            signal_external_workflow => { name => $input->get('signal') }));
}

# StartNexusOperation:{service}/{operation} (Python :822-831); plain-string
# nexus header injection (str_headers => 1), never a _tracer-data Payload.
sub start_nexus_operation ($self, $input) {
    my $root = $self->{root};
    my $name = ($input->get('service') // '') . '/'
        . ($input->get('operation') // '');
    return $self->_traced_call('start_nexus_operation', $input, 'client',
        $root->_outbound_span_name(start_nexus_operation => { name => $name }),
        str_headers => 1);
}

# continue_as_new: NO span at all (Python _context_to_headers:762-765), just
# inject the run's cached context into the outbound headers, unconditionally
# (Python has no replay gate here either; the control signal dies out through
# $next regardless).
sub continue_as_new ($self, $input) {
    my $root = $self->{root};
    my $next = $self->{next};
    return $next->continue_as_new($input) unless $root->tracer;

    my $inbound = $self->{inbound};
    my $carrier = $inbound ? $inbound->{wf_carrier} : undef;
    my $context = defined $carrier ? $root->_carrier_to_context($carrier) : undef;
    $input->headers($root->_inject_headers($input->headers, $context));
    return $next->continue_as_new($input);
}

sub info ($self, $input) { $self->{next}->info($input) }

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Contrib::OpenTelemetry::TracingInterceptor - OpenTelemetry tracing
interceptor (spec section 27.4)

=head1 SYNOPSIS

    use Temporalio::Contrib::OpenTelemetry::TracingInterceptor;

    my $i = Temporalio::Contrib::OpenTelemetry::TracingInterceptor->new(
        tracer     => $otel_tracer,          # defaults to a real OTel tracer
        header_key => '_tracer-data',        #   when OpenTelemetry is installed
        propagator => $w3c_composite,
        always_create_workflow_spans => 0,
    );

    my $client = Temporalio::Client->connect(..., interceptors => [$i]);
    my $worker = Temporalio::Worker->new(..., interceptors => [$i]);

=head1 DESCRIPTION

A single interceptor consuming the client, activity-inbound, and
workflow-inbound roles (spec section 27.4). With a tracer configured it
creates spans on each intercepted surface and propagates the trace context
across the Temporal boundary via the C<_tracer-data> header (MUST-match),
whose value is a Payload carrying the propagator carrier (a C<Str> to C<Str>
map of W3C C<traceparent> / C<tracestate> / C<baggage>). Span names, kinds,
attributes, and the error-status rule match the sdk-python OpenTelemetry
contrib interceptor.

The injected header value is a real L<Temporalio::Payload> (the generated
C<temporal.api.common.v1.Payload> class), not a payload-shaped hashref, so
every outbound path carries it to the wire unchanged: the shared header
contract in L<Temporalio::Interceptor::Headers> passes an already-Payload
value through rather than encoding it a second time. A receiver therefore
recovers the carrier with a B<single> decode, which is what sdk-python does
(C<from_payloads([header_payload])[0]>; its header type is
C<Mapping[str, Payload]> in both directions). On the way back in, the payload
is read by duck-typing its C<metadata>/C<data> accessors, because payloads
materialized from the wire inside another message are instances of the
generated parent class rather than of L<Temporalio::Payload>.

=over 4

=item * B<Client calls> (C<start_workflow>, C<signal_with_start_workflow>,
C<signal_workflow>, C<query_workflow>, C<start_workflow_update>): a
client-kind span named C<StartWorkflow:{wf}> / C<SignalWithStartWorkflow:{wf}>
/ C<SignalWorkflow:{signal}> / C<QueryWorkflow:{query}> /
C<StartWorkflowUpdate:{update}> with a C<temporalWorkflowID> attribute; the
new span's context is B<injected> into the outbound headers. On failure the
span status is set to ERROR unless the error is a benign
L<Temporalio::Exception::Application>.

=item * B<Activity execution>: a server-kind C<RunActivity:{type}> span
parented on the context B<extracted> from the inbound C<_tracer-data> header,
with C<temporalActivityID> / C<temporalWorkflowID> / C<temporalRunID>
attributes. The same ERROR-status rule applies.

=item * B<Workflow tasks and handlers>: zero-duration completed spans stamped
at workflow time (replay-safe; skipped while replaying except query spans) —
C<RunWorkflow:{type}> and C<CompleteWorkflow:{type}> around the run body, and
C<HandleSignal:{signal}> / C<HandleQuery:{query}> / C<ValidateUpdate:{update}>
/ C<HandleUpdate:{update}> per handler dispatch — parented on the context
extracted from the workflow's start headers. A handler input carrying its own
C<_tracer-data> header contributes a span link; query spans parent on the
query header context and are not created without one. Workflow spans are
created only when an inbound parent context is present unless
C<always_create_workflow_spans> is set (no orphans for CLI/schedule starts).

=item * B<Workflow-outbound operations> (C<execute_activity> /
C<execute_local_activity>, both named C<StartActivity:{activity}>;
C<start_child_workflow>, C<StartChildWorkflow:{workflow}>;
C<signal_child_workflow>, C<SignalChildWorkflow:{signal}> (server-kind);
C<signal_external_workflow>, C<SignalExternalWorkflow:{signal}>;
C<start_nexus_operation>, C<StartNexusOperation:{service}/{operation}>): a
zero-duration completed span per call, parented on the run's inbound context,
with the B<new> span's context B<injected> into that op's outbound headers so
a downstream inbound interceptor sees it as its parent. Each op injects its
B<own> span's context, not the run's; an inbound C<_tracer-data> header
already on the op is replaced, not duplicated, and unrelated header keys are
left alone. Skipped entirely while replaying (no span, no header injection),
the same gate the workflow task and handler spans use, and subject to the
same parent-missing gate: with C<always_create_workflow_spans> off (the
default) a run that started without a C<_tracer-data> header has no context
to parent on, so an outbound op creates no span B<and> injects no header;
turning the option on gives it both, with the new span parentless.
C<continue_as_new> is the one exception: it creates B<no> span at all and
only injects the run's context into its outbound headers, which means it
injects nothing when that context is absent. C<start_nexus_operation>'s
injection writes the carrier's keys directly into the plain C<Str> to C<Str>
C<nexus_header> map (never a C<_tracer-data> Payload); every other op uses
the same C<_tracer-data> Payload header as the inbound side.

=back

L<OpenTelemetry> and L<OpenTelemetry::SDK> are optional. The module loads and
constructs without them. When constructed without a C<tracer> argument it
defaults to a real OTel tracer if L<OpenTelemetry> is installed and to undef
otherwise; without a tracer every wrapper delegates unchanged (no spans, no
headers). Passing C<< tracer => undef >> explicitly forces that headless mode.
Any object satisfying the small tracer surface the interceptor drives —
C<create_span(name/kind/attributes/parent/links/start_timestamp)> returning a
span with C<set_status> / C<record_exception> / C<end> — works as a C<tracer>;
with a non-OTel tracer, kinds and the error status are the plain strings
C<client> / C<server> / C<internal> / C<error>.

Header propagation needs a C<propagator> (C<inject($carrier, $context)> /
C<extract($carrier)>). With a real OTel tracer and no explicit propagator the
W3C TraceContext + Baggage composite is used; with no propagator at all the
inject side writes no header and the extract side hands the raw carrier map to
C<create_span> as the parent.

=head1 CONSTRUCTOR

=head2 new

C<< ->new(tracer => $t, header_key => '_tracer-data', propagator => $p, always_create_workflow_spans => 0) >>.
All keys are optional: C<tracer> defaults to a real OTel tracer when
L<OpenTelemetry> is installed (undef otherwise; C<< tracer => undef >> forces
headless mode), C<header_key> defaults to C<_tracer-data>, C<propagator>
defaults to the W3C composite for a real tracer, and
C<always_create_workflow_spans> defaults to false.

=head1 METHODS

=head2 tracer / header_key / propagator / always_create_workflow_spans

Accessors for the configured values.

=head2 intercept_client / intercept_activity / intercept_workflow

The role hooks (spec section 27.1). Each returns a framework-conforming
wrapper implementing the span creation and carrier inject/extract described
above when a tracer is configured, and pure delegation otherwise.

=cut
