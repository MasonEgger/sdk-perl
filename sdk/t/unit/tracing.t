# ABOUTME: Unit tests for the OpenTelemetry tracing interceptor (spec R22/R41/R42,
# ABOUTME: v1 spec section 27.4): drives the PUBLIC wrapper surface with a fake
# ABOUTME: tracer/propagator (t/lib/FakeOTel.pm) — spans per intercepted surface,
# ABOUTME: _tracer-data inject/extract round-trip, error status, replay-safe
# ABOUTME: workflow spans — plus the headless helpers and the OTel-gated fixture.
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;
use JSON::PP ();

use Temporalio::Contrib::OpenTelemetry::TracingInterceptor ();
use Temporalio::Client::Interceptor ();
use Temporalio::Worker::Interceptor ();
use Temporalio::Workflow::Unsafe ();
use Temporalio::Exception::Application ();
use FakeOTel ();

# The Temporalio::*::Interceptor modules pull Future::AsyncAwait's parser hook
# into the compilation unit, which disables Test2::V1's bareword exports for code
# that follows the `use`. Use the T2-> package form for every assertion (the
# same idiom as t/unit/interceptors.t).

my $TI = 'Temporalio::Contrib::OpenTelemetry::TracingInterceptor';

# Whether a real OpenTelemetry stack is installed. Only the R42 gated subtest
# (real default tracer + API-compat smoke) requires it; every span/header
# assertion below runs headlessly against the FakeOTel scaffold (T-trace-8).
my $HAVE_OTEL = eval { require OpenTelemetry; require OpenTelemetry::SDK; 1 } ? 1 : 0;

# A `Str => Payload` header value carrying a W3C carrier, as the client side
# would have written it (the json/plain carrier shape, v1 spec section 27.4).
# Signature-less: a signatured sub before the `class :isa` fixtures trips the
# Future::AsyncAwait attribute-parser leak (same family as lessons.md:106).
sub carrier_payload {
    my ($carrier) = @_;
    return {
        metadata => { encoding => 'json/plain' },
        data     => JSON::PP->new->canonical->utf8->encode($carrier),
    };
}

my $TP1 = '00-' . ('1' x 32) . '-' . ('a' x 16) . '-01';
my $TP2 = '00-' . ('2' x 32) . '-' . ('b' x 16) . '-01';
my $TP3 = '00-' . ('3' x 32) . '-' . ('c' x 16) . '-01';

# --------------------------------------------------------------------------
# Recording chain terminals (the interceptors.t fixture shape: `class :isa`,
# signature-less methods, args from @_ — a `field :param = <default>` next to
# a signatured method poisons the 5.38 parser under Future::AsyncAwait).
# --------------------------------------------------------------------------

class RecClientNext :isa(Temporalio::Client::OutboundInterceptor) {
    field $seen :param;
    field $fail :param = undef;
    async method start_workflow {
        my ($in) = @_;
        $seen->{start_workflow} = $in;
        die $fail if defined $fail;
        return 'res-start_workflow';
    }
    async method signal_with_start_workflow {
        my ($in) = @_;
        $seen->{signal_with_start_workflow} = $in;
        die $fail if defined $fail;
        return 'res-signal_with_start_workflow';
    }
    async method signal_workflow {
        my ($in) = @_;
        $seen->{signal_workflow} = $in;
        die $fail if defined $fail;
        return 'res-signal_workflow';
    }
    async method query_workflow {
        my ($in) = @_;
        $seen->{query_workflow} = $in;
        die $fail if defined $fail;
        return 'res-query_workflow';
    }
    async method start_workflow_update {
        my ($in) = @_;
        $seen->{start_workflow_update} = $in;
        die $fail if defined $fail;
        return 'res-start_workflow_update';
    }
}

class RecActivityNext :isa(Temporalio::Worker::ActivityInbound) {
    field $seen :param;
    field $fail :param = undef;
    async method execute_activity {
        my ($in) = @_;
        $seen->{execute_activity} = $in;
        die $fail if defined $fail;
        return 'act-done';
    }
}

class RecWorkflowNext :isa(Temporalio::Worker::WorkflowInbound) {
    field $seen :param;
    field $fail :param = undef;
    method execute_workflow {
        my ($in) = @_;
        $seen->{execute_workflow} = $in;
        return defined $fail ? Future->fail($fail) : Future->done('wf-done');
    }
    method handle_signal   { my ($in) = @_; $seen->{handle_signal}   = $in; return 'sig-done' }
    method handle_query    { my ($in) = @_; $seen->{handle_query}    = $in; return 'q-done' }
    method validate_update { my ($in) = @_; $seen->{validate_update} = $in; return 'v-done' }
    method handle_update   { my ($in) = @_; $seen->{handle_update}   = $in; return 'u-done' }
}

# --------------------------------------------------------------------------
# R22 + R41: client outbound surface — a span per call, context injected into
# the outbound headers. MUTATION CHECK (R41): these assertions drive the public
# wrapper surface (intercept_client via build_outbound_chain); reverting the
# R22 implementation to delegation-only creates no spans and injects no
# _tracer-data header, failing every assertion in this subtest.
# --------------------------------------------------------------------------
T2->subtest('R22/R41 client outbound: spans + header inject' => sub {
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);
    my %seen;
    my $chain = Temporalio::Client::Interceptor::build_outbound_chain(
        [$i], RecClientNext->new(seen => \%seen));

    # start_workflow: StartWorkflow:{wf} (MUST-match sdk-python
    # contrib/opentelemetry/_interceptor.py:275-287).
    my $res = $chain->start_workflow(
        Temporalio::Client::Interceptor::Input::StartWorkflow->new(
            workflow => 'Greet', kwargs => { id => 'wf-1' }))->get;
    T2->is($res, 'res-start_workflow', 'delegation result preserved');

    my $spans = $tracer->spans_named('StartWorkflow:Greet');
    T2->is(scalar @$spans, 1, 'one StartWorkflow:Greet span created');
    my $span = $spans->[0];
    T2->is($span->kind, 'client', 'client span kind');
    T2->is($span->attributes, { temporalWorkflowID => 'wf-1' },
        'temporalWorkflowID attribute');
    T2->ok($span->ended, 'span ended when the call resolved');
    T2->ok(!defined $span->status, 'no error status on success');

    my $hdr = $seen{start_workflow}->headers->{'_tracer-data'};
    T2->ok(defined $hdr, '_tracer-data header injected on the outbound input');
    my $carrier = $i->_payload_to_carrier($hdr);
    T2->is($carrier->{traceparent}, $span->traceparent,
        'injected carrier round-trips the created span context');

    # signal / query / update span names + header inject on each surface.
    $chain->signal_workflow(
        Temporalio::Client::Interceptor::Input::SignalWorkflow->new(
            signal => 'pause', id => 'wf-1'))->get;
    T2->is(scalar @{ $tracer->spans_named('SignalWorkflow:pause') }, 1,
        'SignalWorkflow:{signal} span');
    T2->ok(defined $seen{signal_workflow}->headers->{'_tracer-data'},
        'signal_workflow header injected');

    $chain->query_workflow(
        Temporalio::Client::Interceptor::Input::QueryWorkflow->new(
            query => 'state', id => 'wf-1'))->get;
    T2->is(scalar @{ $tracer->spans_named('QueryWorkflow:state') }, 1,
        'QueryWorkflow:{query} span');
    T2->ok(defined $seen{query_workflow}->headers->{'_tracer-data'},
        'query_workflow header injected');

    $chain->start_workflow_update(
        Temporalio::Client::Interceptor::Input::StartWorkflowUpdate->new(
            update => 'bump', id => 'wf-1'))->get;
    T2->is(scalar @{ $tracer->spans_named('StartWorkflowUpdate:bump') }, 1,
        'StartWorkflowUpdate:{update} span');
    T2->ok(defined $seen{start_workflow_update}->headers->{'_tracer-data'},
        'start_workflow_update header injected');

    # signal_with_start_workflow has no top-level headers (spec section 27.1):
    # the context is injected into the embedded start op's kwargs headers.
    $chain->signal_with_start_workflow(
        Temporalio::Client::Interceptor::Input::SignalWithStartWorkflow->new(
            workflow => 'Greet', kwargs => { id => 'wf-2', signal => 'go' }))->get;
    T2->is(scalar @{ $tracer->spans_named('SignalWithStartWorkflow:Greet') }, 1,
        'SignalWithStartWorkflow:{wf} span');
    T2->ok(defined $seen{signal_with_start_workflow}
            ->get('kwargs')->{headers}{'_tracer-data'},
        'signal_with_start injects into the embedded start headers');
});

# --------------------------------------------------------------------------
# R22: client outbound error status — ERROR on failure EXCEPT a benign
# ApplicationError (MUST-match sdk-python _start_as_current_span:209-220).
# --------------------------------------------------------------------------
T2->subtest('R22 client outbound: error status on failure' => sub {
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);

    my $failing = $i->intercept_client(
        RecClientNext->new(seen => {}, fail => "kaboom\n"));
    my $f = $failing->start_workflow(
        Temporalio::Client::Interceptor::Input::StartWorkflow->new(
            workflow => 'Greet', kwargs => { id => 'wf-1' }));
    T2->ok($f->is_failed, 'failure propagates to the caller');
    my $span = $tracer->spans->[-1];
    T2->is($span->status, 'error', 'plain failure sets ERROR status');
    T2->ok($span->ended, 'failed span still ended');

    my $benign = Temporalio::Exception::Application->new(
        message => 'expected', category => 'benign');
    my $benign_chain = $i->intercept_client(
        RecClientNext->new(seen => {}, fail => $benign));
    my $bf = $benign_chain->start_workflow(
        Temporalio::Client::Interceptor::Input::StartWorkflow->new(
            workflow => 'Greet', kwargs => { id => 'wf-1' }));
    T2->ok($bf->is_failed, 'benign failure still propagates');
    my $bspan = $tracer->spans->[-1];
    T2->ok(!defined $bspan->status,
        'a benign ApplicationError does NOT set ERROR status');
    T2->ok($bspan->ended, 'benign-failure span still ended');
});

# --------------------------------------------------------------------------
# R22 + R41: activity inbound surface — RunActivity span parented on the
# context EXTRACTED from the _tracer-data header (the inbound half of the
# round trip). MUTATION CHECK (R41): a delegation-only stub creates no span.
# --------------------------------------------------------------------------
T2->subtest('R22/R41 activity inbound: span + header extract' => sub {
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);
    my %seen;
    my $ai = $i->intercept_activity(RecActivityNext->new(seen => \%seen));

    my $res = $ai->execute_activity(
        Temporalio::Worker::Interceptor::Input::ExecuteActivity->new(
            args    => [],
            headers => { '_tracer-data' => carrier_payload({ traceparent => $TP1 }) },
            info    => {
                activity_type   => 'Charge',
                activity_id     => 'a1',
                workflow_id     => 'wf-1',
                workflow_run_id => 'r1',
            }))->get;
    T2->is($res, 'act-done', 'delegation result preserved');

    my $spans = $tracer->spans_named('RunActivity:Charge');
    T2->is(scalar @$spans, 1, 'one RunActivity:Charge span created');
    my $span = $spans->[0];
    T2->is($span->kind, 'server', 'server span kind');
    T2->is($span->attributes, {
        temporalActivityID => 'a1',
        temporalWorkflowID => 'wf-1',
        temporalRunID      => 'r1',
    }, 'activity/workflow/run id attributes (Python parity)');
    T2->ok($span->ended, 'span ended when the activity resolved');
    T2->isa_ok($span->parent, ['FakeOTel::Context'],
        'span parented on an extracted context');
    T2->is($span->parent->carrier->{traceparent}, $TP1,
        'parent context extracted from the _tracer-data header');

    # Error status on activity failure.
    my $failing = $i->intercept_activity(
        RecActivityNext->new(seen => {}, fail => "act-boom\n"));
    my $f = $failing->execute_activity(
        Temporalio::Worker::Interceptor::Input::ExecuteActivity->new(
            args => [], info => { activity_type => 'Charge' }));
    T2->ok($f->is_failed, 'activity failure propagates');
    T2->is($tracer->spans->[-1]->status, 'error',
        'failed activity span sets ERROR status');
});

# --------------------------------------------------------------------------
# R22 + R41: workflow inbound surface — zero-duration completed spans for the
# run body and each handler, parented on the workflow's inbound context.
# MUTATION CHECK (R41): a delegation-only stub creates none of these spans.
# --------------------------------------------------------------------------
T2->subtest('R22/R41 workflow inbound: completed spans per surface' => sub {
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);
    my %seen;
    my $wi = $i->intercept_workflow(RecWorkflowNext->new(seen => \%seen));

    my $res = $wi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type    => 'Greet',
            args    => [],
            headers => { '_tracer-data' => carrier_payload({ traceparent => $TP1 }) },
        ))->get;
    T2->is($res, 'wf-done', 'delegation result preserved');

    my $run = $tracer->spans_named('RunWorkflow:Greet');
    T2->is(scalar @$run, 1, 'one RunWorkflow:{type} span (Python parity name)');
    T2->is($run->[0]->kind, 'server', 'RunWorkflow is a server span');
    T2->is($run->[0]->parent->carrier->{traceparent}, $TP1,
        'RunWorkflow parented on the extracted start-header context');
    T2->ok(defined $run->[0]->start_timestamp
        && $run->[0]->ended
        && $run->[0]->end_timestamp == $run->[0]->start_timestamp,
        'RunWorkflow is a zero-duration completed span (replay-safe)');

    my $complete = $tracer->spans_named('CompleteWorkflow:Greet');
    T2->is(scalar @$complete, 1, 'CompleteWorkflow:{type} span on completion');
    T2->is($complete->[0]->kind, 'internal', 'CompleteWorkflow is internal');

    # handle_signal without its own header: parented on the cached workflow
    # context from the execute_workflow headers.
    $wi->handle_signal(
        Temporalio::Worker::Interceptor::Input::HandleSignal->new(
            signal => 'go'));
    my $sig = $tracer->spans_named('HandleSignal:go');
    T2->is(scalar @$sig, 1, 'HandleSignal:{signal} span');
    T2->is($sig->[0]->parent->carrier->{traceparent}, $TP1,
        'handler span parented on the workflow context');

    # handle_signal WITH a header: the sender context arrives as a LINK
    # (Python parity: handle_signal link_context_carrier).
    $wi->handle_signal(
        Temporalio::Worker::Interceptor::Input::HandleSignal->new(
            signal  => 'go2',
            headers => { '_tracer-data' => carrier_payload({ traceparent => $TP2 }) }));
    my $sig2 = $tracer->spans_named('HandleSignal:go2');
    T2->is(scalar @$sig2, 1, 'HandleSignal span with sender header');
    T2->is($sig2->[0]->links->[0]->carrier->{traceparent}, $TP2,
        'sender context linked, not parented');

    # handle_query WITHOUT a header creates no span (Python parity: query spans
    # are parented on the query header context only).
    $wi->handle_query(
        Temporalio::Worker::Interceptor::Input::HandleQuery->new(
            query => 'silent'));
    T2->is(scalar @{ $tracer->spans_named('HandleQuery:silent') }, 0,
        'no HandleQuery span without a query header');

    # handle_query WITH a header: parented on the query context, linked to the
    # workflow context.
    $wi->handle_query(
        Temporalio::Worker::Interceptor::Input::HandleQuery->new(
            query   => 'state',
            headers => { '_tracer-data' => carrier_payload({ traceparent => $TP3 }) }));
    my $q = $tracer->spans_named('HandleQuery:state');
    T2->is(scalar @$q, 1, 'HandleQuery:{query} span with header');
    T2->is($q->[0]->parent->carrier->{traceparent}, $TP3,
        'query span parented on the query header context');
    T2->is($q->[0]->links->[0]->carrier->{traceparent}, $TP1,
        'query span linked to the workflow context');

    # validate_update / handle_update span names.
    $wi->validate_update(
        Temporalio::Worker::Interceptor::Input::HandleUpdate->new(
            update => 'bump'));
    T2->is(scalar @{ $tracer->spans_named('ValidateUpdate:bump') }, 1,
        'ValidateUpdate:{update} span');
    $wi->handle_update(
        Temporalio::Worker::Interceptor::Input::HandleUpdate->new(
            update => 'bump'));
    T2->is(scalar @{ $tracer->spans_named('HandleUpdate:bump') }, 1,
        'HandleUpdate:{update} span');
});

# --------------------------------------------------------------------------
# R22: workflow-span gating — no parent context and always_create_workflow_spans
# unset means NO workflow spans (no orphans for CLI/schedule starts); =1 always.
# --------------------------------------------------------------------------
T2->subtest('R22 workflow spans gated on inbound parent context' => sub {
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);
    my $wi = $i->intercept_workflow(RecWorkflowNext->new(seen => {}));
    $wi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type => 'Greet', args => []))->get;
    T2->is(scalar @{ $tracer->spans }, 0,
        'no workflow spans without an inbound parent context (default)');

    my $always_tracer = FakeOTel::Tracer->new;
    my $always = $TI->new(
        tracer => $always_tracer, propagator => FakeOTel::Propagator->new,
        always_create_workflow_spans => 1);
    my $awi = $always->intercept_workflow(RecWorkflowNext->new(seen => {}));
    $awi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type => 'Greet', args => []))->get;
    T2->is(scalar @{ $always_tracer->spans_named('RunWorkflow:Greet') }, 1,
        'always_create_workflow_spans=1 creates the span with no parent');
});

# --------------------------------------------------------------------------
# R22: CompleteWorkflow on failure — a Temporalio::Exception failure records
# the exception; a plain die (a task failure, not a workflow completion) does
# NOT produce a CompleteWorkflow span (Python parity: FailureError only).
# --------------------------------------------------------------------------
T2->subtest('R22 CompleteWorkflow on failure' => sub {
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);

    my $boom = Temporalio::Exception::Application->new(message => 'boom');
    my $wi = $i->intercept_workflow(RecWorkflowNext->new(seen => {}, fail => $boom));
    my $f = $wi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type    => 'Greet',
            args    => [],
            headers => { '_tracer-data' => carrier_payload({ traceparent => $TP1 }) },
        ));
    T2->ok($f->is_failed, 'workflow failure propagates');
    my $complete = $tracer->spans_named('CompleteWorkflow:Greet');
    T2->is(scalar @$complete, 1, 'CompleteWorkflow span on workflow failure');
    T2->is($complete->[0]->exceptions, [$boom], 'the failure is recorded');

    my $t2 = FakeOTel::Tracer->new;
    my $i2 = $TI->new(tracer => $t2, propagator => FakeOTel::Propagator->new);
    my $wi2 = $i2->intercept_workflow(
        RecWorkflowNext->new(seen => {}, fail => "task-boom\n"));
    my $f2 = $wi2->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type    => 'Greet',
            args    => [],
            headers => { '_tracer-data' => carrier_payload({ traceparent => $TP1 }) },
        ));
    T2->ok($f2->is_failed, 'plain die still propagates');
    T2->is(scalar @{ $t2->spans_named('CompleteWorkflow:Greet') }, 0,
        'no CompleteWorkflow span for a non-Failure die (task failure)');
});

# --------------------------------------------------------------------------
# R22: no tracer configured — every wrapper delegates unchanged (headless
# no-op), no header is added, nothing dies.
# --------------------------------------------------------------------------
T2->subtest('R22 headless: no tracer means pure delegation' => sub {
    my $i = $TI->new;
    T2->ok(!defined $i->tracer || $HAVE_OTEL,
        'no tracer without OpenTelemetry installed');

    my $headless = $TI->new(tracer => undef);
    # Force the tracer-less path even when OTel is installed.
    my %seen;
    my $chain = Temporalio::Client::Interceptor::build_outbound_chain(
        [$headless], RecClientNext->new(seen => \%seen));
    my $res = $chain->start_workflow(
        Temporalio::Client::Interceptor::Input::StartWorkflow->new(
            workflow => 'Greet', kwargs => { id => 'wf-1' }))->get;
    T2->is($res, 'res-start_workflow', 'tracer-less client call delegates');
    T2->ok(!exists $seen{start_workflow}->headers->{'_tracer-data'},
        'no header injected without a tracer');

    my $ai = $headless->intercept_activity(RecActivityNext->new(seen => \%seen));
    T2->is($ai->execute_activity(
        Temporalio::Worker::Interceptor::Input::ExecuteActivity->new(
            args => [], info => { activity_type => 'Charge' }))->get,
        'act-done', 'tracer-less activity call delegates');

    my $wi = $headless->intercept_workflow(RecWorkflowNext->new(seen => \%seen));
    T2->is($wi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type => 'Greet', args => []))->get,
        'wf-done', 'tracer-less workflow call delegates');
});

# --------------------------------------------------------------------------
# T-trace-2: header key + carrier round-trip via the built-in W3C shim.
# --------------------------------------------------------------------------
T2->subtest('T-trace-2 header key and carrier round-trip' => sub {
    my $i = $TI->new;

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
# T-trace-4: span-name table (MUST-match sdk-python contrib/opentelemetry
# _interceptor.py; RunWorkflow/CompleteWorkflow carry the workflow type
# suffix per _interceptor.py:507 and :656 — sdk-ruby open_telemetry.rb:247
# and :251 agree).
# --------------------------------------------------------------------------
T2->subtest('T-trace-4 span-name table' => sub {
    my $i = $TI->new;

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

    T2->is($i->_workflow_span_name('run_workflow', { name => 'Greet' }),
        'RunWorkflow:Greet', 'RunWorkflow:{type} (Python parity)');
    T2->is($i->_workflow_span_name('complete_workflow', { name => 'Greet' }),
        'CompleteWorkflow:Greet', 'CompleteWorkflow:{type} (Python parity)');
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
    my $i = $TI->new;

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
# T-trace-6 (headless): span status is ERROR on exception EXCEPT a benign
# ApplicationError.
# --------------------------------------------------------------------------
T2->subtest('T-trace-6 benign ApplicationError not ERROR' => sub {
    my $i = $TI->new;

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
    my $def = $TI->new;
    T2->ok(!$def->always_create_workflow_spans,
        'always_create_workflow_spans defaults to 0');
    T2->ok($def->_should_create_workflow_span(1),
        'with parent context present, a span is created (default)');
    T2->ok(!$def->_should_create_workflow_span(0),
        'with no parent context, no span is created (default)');

    my $always = $TI->new(always_create_workflow_spans => 1);
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
# R42 (T-trace-8 gate): with a real OpenTelemetry stack installed, the
# constructor defaults to a real tracer (Python parity: get_tracer) and the
# wrapper drives the real API without dying. Skips when OTel is absent; the
# suite passes either way (R42 required behavior).
# --------------------------------------------------------------------------
T2->subtest('R42 real-OTel fixture: default tracer + API-compat smoke' => sub {
    T2->plan(skip_all =>
        'OpenTelemetry + OpenTelemetry::SDK not installed (T-trace-8)')
        unless $HAVE_OTEL;

    my $i = $TI->new;
    T2->ok(defined $i->tracer,
        'tracer defaults to a real OTel tracer when OpenTelemetry is installed');
    T2->isa_ok($i->tracer, ['OpenTelemetry::Trace::Tracer'],
        'the default tracer is an OpenTelemetry::Trace::Tracer');

    # API-compat smoke: a client call through the wrapper with the real tracer
    # and the real default W3C propagator completes and delegates. (Span
    # recording needs a configured SDK tracer provider; without one the spans
    # are valid no-ops and injection yields an empty carrier.)
    my %seen;
    my $chain = Temporalio::Client::Interceptor::build_outbound_chain(
        [$i], RecClientNext->new(seen => \%seen));
    my $res = $chain->start_workflow(
        Temporalio::Client::Interceptor::Input::StartWorkflow->new(
            workflow => 'Greet', kwargs => { id => 'wf-otel' }))->get;
    T2->is($res, 'res-start_workflow',
        'real-tracer client call drives the real API and delegates');

    my $wi = $i->intercept_workflow(RecWorkflowNext->new(seen => \%seen));
    my $wres = $wi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type    => 'Greet',
            args    => [],
            headers => { '_tracer-data' => carrier_payload({ traceparent => $TP1 }) },
        ))->get;
    T2->is($wres, 'wf-done',
        'real-tracer workflow call drives the real API and delegates');
});

T2->done_testing;
