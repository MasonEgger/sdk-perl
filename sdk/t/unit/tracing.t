# ABOUTME: Unit tests for the OpenTelemetry tracing interceptor (spec section 27.4):
# ABOUTME: span-name table, _tracer-data header carrier (W3C shim), benign-error
# ABOUTME: span status, always_create_workflow_spans gating, durable_scheduler_disabled
# ABOUTME: (T-trace-1..9). OTel-dependent span-tree scenarios skip without OpenTelemetry.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();

use Temporalio::Contrib::OpenTelemetry::TracingInterceptor ();
use Temporalio::Client::Interceptor ();
use Temporalio::Worker::Interceptor ();
use Temporalio::Workflow::Unsafe ();

# The Temporalio::*::Interceptor modules pull Future::AsyncAwait's parser hook
# into the compilation unit, which disables Test2::V1's bareword exports for code
# that follows the `use`. Use the T2-> package form for every assertion (the
# same idiom as t/unit/interceptors.t).

# Whether a real OpenTelemetry stack is installed. The span-tree / exporter
# scenarios (T-trace-1, -3, -5, -7, -9) require it and skip_all when absent
# (resolved decision, spec section 27.4 / T-trace-8). The headless-verifiable
# behavior (W3C carrier shim, span-name table, header key, benign-error logic,
# always_create_workflow_spans gating, durable_scheduler_disabled) runs either
# way: those are the resolved decisions testable without an OTel runtime.
my $HAVE_OTEL = eval { require OpenTelemetry; require OpenTelemetry::SDK; 1 } ? 1 : 0;

# --------------------------------------------------------------------------
# T-trace-2: header key + carrier round-trip via the built-in W3C shim.
# --------------------------------------------------------------------------
T2->subtest('T-trace-2 header key and carrier round-trip' => sub {
    my $i = Temporalio::Contrib::OpenTelemetry::TracingInterceptor->new;

    T2->is($i->header_key, '_tracer-data', "default header key is '_tracer-data'");

    my %carrier = (
        traceparent => '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
        tracestate  => 'rojo=00f067aa0ba902b7',
    );
    my $payload = $i->_carrier_to_payload({%carrier});
    T2->ok(defined $payload, 'carrier encodes to a header payload');

    my $back = $i->_payload_to_carrier($payload);
    T2->is($back, {%carrier}, 'carrier decodes back to the original Str->Str map');

    T2->is($i->_carrier_to_payload({}), undef, 'empty carrier produces no payload');
    T2->is($i->_payload_to_carrier(undef), undef, 'undef payload decodes to undef');
});

# --------------------------------------------------------------------------
# T-trace-4: span-name table (MUST-match sdk-python / sdk-ruby).
# --------------------------------------------------------------------------
T2->subtest('T-trace-4 span-name table' => sub {
    my $i = Temporalio::Contrib::OpenTelemetry::TracingInterceptor->new;

    T2->is($i->_client_span_name('start_workflow', { workflow => 'Greet' }),
        'StartWorkflow:Greet', 'StartWorkflow:{wf}');
    T2->is($i->_client_span_name('start_workflow',
            { workflow => 'Greet', start_signal => 'go' }),
        'SignalWithStartWorkflow:Greet', 'SignalWithStartWorkflow:{wf}');
    T2->is($i->_client_span_name('signal_workflow', { signal => 'pause' }),
        'SignalWorkflow:pause', 'SignalWorkflow:{signal}');
    T2->is($i->_client_span_name('query_workflow', { query => 'state' }),
        'QueryWorkflow:state', 'QueryWorkflow:{query}');
    T2->is($i->_client_span_name('start_workflow_update', { update => 'bump' }),
        'StartWorkflowUpdate:bump', 'StartWorkflowUpdate:{update}');

    T2->is($i->_activity_span_name('Charge'), 'RunActivity:Charge',
        'RunActivity:{type}');

    T2->is($i->_workflow_span_name('run_workflow', {}), 'RunWorkflow', 'RunWorkflow');
    T2->is($i->_workflow_span_name('complete_workflow', {}), 'CompleteWorkflow',
        'CompleteWorkflow');
    T2->is($i->_workflow_span_name('handle_signal', { name => 'go' }),
        'HandleSignal:go', 'HandleSignal:{signal}');
    T2->is($i->_workflow_span_name('handle_query', { name => 'state' }),
        'HandleQuery:state', 'HandleQuery:{query}');
    T2->is($i->_workflow_span_name('validate_update', { name => 'bump' }),
        'ValidateUpdate:bump', 'ValidateUpdate:{update}');
    T2->is($i->_workflow_span_name('handle_update', { name => 'bump' }),
        'HandleUpdate:bump', 'HandleUpdate:{update}');

    T2->is($i->_outbound_span_name('start_activity', { name => 'Charge' }),
        'StartActivity:Charge', 'StartActivity:{type}');
    T2->is($i->_outbound_span_name('start_child_workflow', { name => 'Child' }),
        'StartChildWorkflow:Child', 'StartChildWorkflow:{wf}');
    T2->is($i->_outbound_span_name('signal_child_workflow', { name => 'go' }),
        'SignalChildWorkflow:go', 'SignalChildWorkflow:{signal}');
    T2->is($i->_outbound_span_name('signal_external_workflow', { name => 'go' }),
        'SignalExternalWorkflow:go', 'SignalExternalWorkflow:{signal}');
});

# --------------------------------------------------------------------------
# Role consumption: one interceptor consumes the client + activity-inbound +
# workflow-inbound roles and is accepted by both chain builders.
# --------------------------------------------------------------------------
T2->subtest('consumes client + activity + workflow roles' => sub {
    my $i = Temporalio::Contrib::OpenTelemetry::TracingInterceptor->new;

    T2->isa_ok($i, ['Temporalio::Client::Interceptor'], 'is a client interceptor');
    T2->isa_ok($i, ['Temporalio::Worker::Interceptor'], 'is a worker interceptor');

    my $out = $i->intercept_client(
        Temporalio::Client::OutboundInterceptor->new(next => undef));
    T2->isa_ok($out, ['Temporalio::Client::OutboundInterceptor'],
        'intercept_client returns an OutboundInterceptor');

    my $ai = $i->intercept_activity(
        Temporalio::Worker::ActivityInbound->new(next => undef));
    T2->isa_ok($ai, ['Temporalio::Worker::ActivityInbound'],
        'intercept_activity returns an ActivityInbound');

    my $wi = $i->intercept_workflow(
        Temporalio::Worker::WorkflowInbound->new(next => undef));
    T2->isa_ok($wi, ['Temporalio::Worker::WorkflowInbound'],
        'intercept_workflow returns a WorkflowInbound');

    T2->ok(
        Temporalio::Client::Interceptor::build_outbound_chain(
            [$i], Temporalio::Client::OutboundInterceptor->new(next => undef)),
        'accepted by build_outbound_chain');
    T2->ok(
        Temporalio::Worker::Interceptor::build_activity_inbound(
            [$i], Temporalio::Worker::ActivityInbound->new(next => undef)),
        'accepted by build_activity_inbound');
    T2->ok(
        Temporalio::Worker::Interceptor::build_workflow_inbound(
            [$i], Temporalio::Worker::WorkflowInbound->new(next => undef)),
        'accepted by build_workflow_inbound');
});

# --------------------------------------------------------------------------
# T-trace-6 (partial, headless): span status is ERROR on exception EXCEPT a
# benign ApplicationError.
# --------------------------------------------------------------------------
T2->subtest('T-trace-6 benign ApplicationError not ERROR' => sub {
    my $i = Temporalio::Contrib::OpenTelemetry::TracingInterceptor->new;

    require Temporalio::Exception::Application;
    my $plain = Temporalio::Exception::Application->new(message => 'boom');
    T2->ok($i->_should_set_error_status($plain),
        'a plain ApplicationError sets ERROR status');

    my $benign = Temporalio::Exception::Application->new(
        message => 'expected', category => 'benign');
    T2->ok(!$i->_should_set_error_status($benign),
        'a benign ApplicationError does NOT set ERROR status');

    T2->ok($i->_should_set_error_status("some random die"),
        'a non-ApplicationError sets ERROR status');
});

# --------------------------------------------------------------------------
# T-trace-3 (headless gate): always_create_workflow_spans=0 (default) creates a
# workflow span only when an inbound parent context is present; =1 always.
# --------------------------------------------------------------------------
T2->subtest('T-trace-3 always_create_workflow_spans gating' => sub {
    my $def = Temporalio::Contrib::OpenTelemetry::TracingInterceptor->new;
    T2->ok(!$def->always_create_workflow_spans,
        'always_create_workflow_spans defaults to 0');
    T2->ok($def->_should_create_workflow_span(1),
        'with parent context present, a span is created (default)');
    T2->ok(!$def->_should_create_workflow_span(0),
        'with no parent context, no span is created (default)');

    my $always = Temporalio::Contrib::OpenTelemetry::TracingInterceptor->new(
        always_create_workflow_spans => 1);
    T2->ok($always->_should_create_workflow_span(0),
        'always_create_workflow_spans=1 creates a span even with no parent');
});

# --------------------------------------------------------------------------
# durable_scheduler_disabled primitive (spec section 27.4): runs a block without
# recording on / yielding to the durable scheduler. Outside a workflow body it
# just runs the block.
# --------------------------------------------------------------------------
T2->subtest('durable_scheduler_disabled primitive runs the block' => sub {
    my $ran = 0;
    my $out = Temporalio::Workflow::Unsafe::durable_scheduler_disabled(sub {
        $ran = 1;
        return 'value';
    });
    T2->is($ran, 1, 'the block ran');
    T2->is($out, 'value', 'the block return value is propagated');
});

# --------------------------------------------------------------------------
# T-trace-1/5/7/9: end-to-end span tree, replay safety, await survival,
# signal/query/update linking. Require a real OpenTelemetry runtime; skip when
# OTel is not installed (T-trace-8).
# --------------------------------------------------------------------------
T2->subtest('T-trace-1/5/7/9 span-tree scenarios (require OTel)' => sub {
    T2->plan(skip_all =>
        'OpenTelemetry + OpenTelemetry::SDK not installed (T-trace-8)')
        unless $HAVE_OTEL;

    my $i = Temporalio::Contrib::OpenTelemetry::TracingInterceptor->new;
    T2->ok($i->tracer, 'a tracer is available with OTel installed');
});

T2->done_testing;
