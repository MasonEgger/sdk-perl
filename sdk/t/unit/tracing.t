# ABOUTME: Unit tests for the OpenTelemetry tracing interceptor (spec R22/R41/R42,
# ABOUTME: v1 spec section 27.4): drives the PUBLIC wrapper surface with a fake
# ABOUTME: tracer/propagator (t/lib/FakeOTel.pm) — spans per intercepted surface,
# ABOUTME: _tracer-data inject/extract round-trip, error status, replay-safe
# ABOUTME: workflow spans; plus the headless helpers, the OTel-gated fixture, and
# ABOUTME: the F1 end-to-end pass: a real Runner driven through the replay harness
# ABOUTME: whose emitted ScheduleActivity header decodes to the carrier in ONE step.
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
use Temporalio::Converter::Payload ();
use Temporalio::Interceptor::Headers ();
use Temporalio::Payload ();
use Temporalio::Test::WorkflowReplay ();
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

# F1: the same carrier as a BLESSED wire Payload, the shape the inbound side
# actually receives (ActivityDispatcher threads the activity Start task's
# header_fields straight into the input, and those are proto Payloads off the
# wire). sdk-python's header type is Mapping[str, Payload] on BOTH sides and
# it builds the value with payload_converter.to_payloads([carrier])[0]
# (contrib/opentelemetry/_interceptor.py:675-682), so a blessed Payload is
# the contract, not a hashref. Signature-less for the same parser reason as
# carrier_payload above.
sub blessed_carrier_payload {
    my ($carrier) = @_;
    return Temporalio::Payload->new({
        metadata => { encoding => 'json/plain' },
        data     => JSON::PP->new->canonical->utf8->encode($carrier),
    });
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
    # init capture (I6): records whatever outbound the OTel interceptor's
    # init() delegates down-chain, so the test can read $seen->{init_outbound}
    # to reach the WRAPPED tracing outbound (the OUTBOUND-SPAN SEAM contract:
    # init wraps $args[0] and delegates the wrapped instance).
    method init { my ($outbound) = @_; $seen->{init_outbound} = $outbound; return }
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

# I6: workflow-outbound chain root fixture: records the Input each traced op
# receives (after any span+inject wrapping) and returns a delegation marker,
# mirroring RecClientNext/RecActivityNext for the outbound surface.
class RecOutboundNext :isa(Temporalio::Worker::WorkflowOutbound) {
    field $seen :param;
    method execute_activity {
        my ($in) = @_; $seen->{execute_activity} = $in; return 'res-execute_activity' }
    method execute_local_activity {
        my ($in) = @_; $seen->{execute_local_activity} = $in;
        return 'res-execute_local_activity' }
    method start_child_workflow {
        my ($in) = @_; $seen->{start_child_workflow} = $in;
        return 'res-start_child_workflow' }
    method signal_child_workflow {
        my ($in) = @_; $seen->{signal_child_workflow} = $in;
        return 'res-signal_child_workflow' }
    method signal_external_workflow {
        my ($in) = @_; $seen->{signal_external_workflow} = $in;
        return 'res-signal_external_workflow' }
    method continue_as_new {
        my ($in) = @_; $seen->{continue_as_new} = $in;
        die "continue_as_new reached the chain root\n" }
    method start_nexus_operation {
        my ($in) = @_; $seen->{start_nexus_operation} = $in;
        return 'res-start_nexus_operation' }
    method info { my ($in) = @_; $seen->{info} = $in; return 'res-info' }
}

# I6 replay fixture: a minimal $Temporalio::Workflow::Runner::CURRENT stand-in
# so _wf_replaying (which reads Temporalio::Workflow::is_replaying, which
# reads $Runner::CURRENT) reports "replaying" without a real Runner. Every
# other headless subtest in this file runs with no $CURRENT set, which raises
# NoRunner inside the eval and so defaults _wf_replaying to false.
package FakeReplayRunner;
sub new ($class) { bless {}, $class }
sub is_replaying    ($self) { 1 }
sub activation_time ($self) { 1700000000 }
sub info             ($self) { {} }
package main;

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
# I6 (closes GitHub #6): workflow-outbound surface: a completed span per
# traced op (the %OUT_SPAN_VERB table), the NEW span's context injected into
# the op's outbound headers, parented on the run's cached inbound context.
# MUST-match sdk-python _TracingWorkflowOutboundInterceptor
# (contrib/opentelemetry/_interceptor.py:751-831): start_activity /
# start_local_activity -> StartActivity:{activity} CLIENT (both reuse the
# same verb, :789-820); start_child_workflow -> StartChildWorkflow:{workflow}
# CLIENT (:800-809); signal_child_workflow -> SignalChildWorkflow:{signal}
# SERVER (:767-776); signal_external_workflow ->
# SignalExternalWorkflow:{signal} CLIENT (:778-787); start_nexus_operation ->
# StartNexusOperation:{service}/{operation} CLIENT with PLAIN STRING headers
# (add_to_outbound_str / _carrier_to_nexus_headers:834-843, NOT a
# _tracer-data Payload, spec section 26.1); continue_as_new injects the run's
# context into headers with NO span at all (_context_to_headers:762-765).
# --------------------------------------------------------------------------
T2->subtest('I6 workflow outbound: spans + header inject per op' => sub {
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);
    my %seen;
    my $wi = $i->intercept_workflow(RecWorkflowNext->new(seen => \%seen));

    # Cache the run's inbound context (execute_workflow with a start header,
    # same scaffolding as the R22 workflow-inbound subtest above): every
    # outbound span below parents on $TP1.
    $wi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type    => 'Greet',
            args    => [],
            headers => { '_tracer-data' => carrier_payload({ traceparent => $TP1 }) },
        ))->get;

    # init() wraps the received outbound (the OUTBOUND-SPAN SEAM contract)
    # and delegates the WRAPPED instance down-chain; RecWorkflowNext's init
    # captures it in $seen->{init_outbound}.
    my %ob_seen;
    $wi->init(RecOutboundNext->new(seen => \%ob_seen));
    my $ob = $seen{init_outbound};
    T2->ok(Scalar::Util::blessed($ob), 'init delegated a wrapped outbound down-chain');
    T2->isa_ok($ob, ['Temporalio::Worker::WorkflowOutbound'],
        'the wrapped outbound is still a WorkflowOutbound');

    # execute_activity -> StartActivity:{activity}, CLIENT.
    my $act_res = $ob->execute_activity(
        Temporalio::Worker::Interceptor::Input::StartActivity->new(
            activity => 'Charge', args => [], headers => {}, kwargs => {}));
    T2->is($act_res, 'res-execute_activity', 'delegation result preserved');
    my $act_spans = $tracer->spans_named('StartActivity:Charge');
    T2->is(scalar @$act_spans, 1, 'StartActivity:{activity} span');
    T2->is($act_spans->[0]->kind, 'client', 'client span kind');
    T2->is($act_spans->[0]->parent->carrier->{traceparent}, $TP1,
        'parented on the cached workflow context');
    my $act_hdr = $ob_seen{execute_activity}->headers->{'_tracer-data'};
    T2->ok(defined $act_hdr, '_tracer-data injected into the activity headers');
    T2->is($i->_payload_to_carrier($act_hdr)->{traceparent},
        $act_spans->[0]->traceparent,
        'injected carrier round-trips the NEW span context');

    # F1: every op injects ITS OWN span's context, not the run's parent. Before
    # F1 only execute_activity asserted the round trip; the other four asserted
    # `defined` only, so an op that injected the cached wf_carrier (or another
    # op's context) would have passed.

    # execute_local_activity reuses the StartActivity verb (Python :811-820).
    $ob->execute_local_activity(
        Temporalio::Worker::Interceptor::Input::StartLocalActivity->new(
            activity => 'LocalCharge', args => [], headers => {}, kwargs => {}));
    my $la_spans = $tracer->spans_named('StartActivity:LocalCharge');
    T2->is(scalar @$la_spans, 1,
        'execute_local_activity reuses the StartActivity:{activity} verb');
    my $la_hdr = $ob_seen{execute_local_activity}->headers->{'_tracer-data'};
    T2->ok(defined $la_hdr, 'local-activity header injected');
    T2->is($i->_payload_to_carrier($la_hdr)->{traceparent},
        $la_spans->[0]->traceparent,
        'the local-activity carrier round-trips ITS OWN span context');

    # start_child_workflow -> StartChildWorkflow:{workflow}, CLIENT.
    $ob->start_child_workflow(
        Temporalio::Worker::Interceptor::Input::StartChildWorkflow->new(
            workflow => 'Child', args => [], headers => {}, kwargs => {}));
    my $child_spans = $tracer->spans_named('StartChildWorkflow:Child');
    T2->is(scalar @$child_spans, 1, 'StartChildWorkflow:{workflow} span');
    T2->is($child_spans->[0]->kind, 'client', 'client span kind');
    my $child_hdr = $ob_seen{start_child_workflow}->headers->{'_tracer-data'};
    T2->ok(defined $child_hdr, 'start_child_workflow header injected');
    T2->is($i->_payload_to_carrier($child_hdr)->{traceparent},
        $child_spans->[0]->traceparent,
        'the child-start carrier round-trips ITS OWN span context');

    # signal_child_workflow -> SignalChildWorkflow:{signal}, SERVER.
    $ob->signal_child_workflow(
        Temporalio::Worker::Interceptor::Input::SignalChildWorkflow->new(
            signal => 'go', child_workflow_id => 'child-1',
            args => [], headers => {}));
    my $sig_child = $tracer->spans_named('SignalChildWorkflow:go');
    T2->is(scalar @$sig_child, 1, 'SignalChildWorkflow:{signal} span');
    T2->is($sig_child->[0]->kind, 'server', 'server span kind (Python parity)');
    my $sig_child_hdr = $ob_seen{signal_child_workflow}->headers->{'_tracer-data'};
    T2->ok(defined $sig_child_hdr, 'signal_child_workflow header injected');
    T2->is($i->_payload_to_carrier($sig_child_hdr)->{traceparent},
        $sig_child->[0]->traceparent,
        'the signal-child carrier round-trips ITS OWN span context');

    # signal_external_workflow -> SignalExternalWorkflow:{signal}, CLIENT. This
    # op also proves REPLACEMENT: it starts with a stale _tracer-data header
    # (a sender context an interceptor above might have left), and the injected
    # map must carry the new span's context under the one key, not both.
    $ob->signal_external_workflow(
        Temporalio::Worker::Interceptor::Input::SignalExternalWorkflow->new(
            signal => 'go', namespace => 'ns', workflow_id => 'ext-1',
            workflow_run_id => undef, args => [],
            headers => {
                '_tracer-data' => carrier_payload({ traceparent => $TP2 }),
                'x-other'      => 'kept',
            }));
    my $sig_ext = $tracer->spans_named('SignalExternalWorkflow:go');
    T2->is(scalar @$sig_ext, 1, 'SignalExternalWorkflow:{signal} span');
    T2->is($sig_ext->[0]->kind, 'client', 'client span kind (Python parity)');
    my $sig_ext_headers = $ob_seen{signal_external_workflow}->headers;
    my $sig_ext_hdr = $sig_ext_headers->{'_tracer-data'};
    T2->ok(defined $sig_ext_hdr, 'signal_external_workflow header injected');
    T2->is($i->_payload_to_carrier($sig_ext_hdr)->{traceparent},
        $sig_ext->[0]->traceparent,
        'a pre-existing _tracer-data header is REPLACED by this span context');
    T2->is($sig_ext_headers->{'x-other'}, 'kept',
        'unrelated headers survive the injection');
    # A Perl hash cannot hold the key twice, so counting keys proves nothing.
    # The claim worth asserting is that the stale value lost: what rides out
    # under the one key is the new span context, never $TP2.
    T2->isnt($i->_payload_to_carrier($sig_ext_hdr)->{traceparent}, $TP2,
        'the stale sender context is gone: replaced, not merged or preferred');

    # start_nexus_operation -> StartNexusOperation:{service}/{operation},
    # CLIENT, PLAIN STRING headers (spec section 26.1: nexus_header is a Str
    # => Str map, never a _tracer-data Payload).
    $ob->start_nexus_operation(
        Temporalio::Worker::Interceptor::Input::StartNexusOperation->new(
            endpoint => 'ep', service => 'svc', operation => 'op',
            input => undef, headers => {}, kwargs => {}));
    my $nexus_spans = $tracer->spans_named('StartNexusOperation:svc/op');
    T2->is(scalar @$nexus_spans, 1,
        'StartNexusOperation:{service}/{operation} span');
    T2->is($nexus_spans->[0]->kind, 'client', 'client span kind');
    my $nexus_hdr = $ob_seen{start_nexus_operation}->headers;
    T2->ok(!exists $nexus_hdr->{'_tracer-data'},
        'nexus headers carry the carrier keys directly, not a _tracer-data Payload');
    T2->is($nexus_hdr->{traceparent}, $nexus_spans->[0]->traceparent,
        'the carrier traceparent key is merged straight into the string header map');

    # continue_as_new: NO span, header injection ONLY, using the run's cached
    # context (Python :762-765 has no replay gate either).
    my $before_span_count = scalar @{ $tracer->spans };
    my $can_input = Temporalio::Worker::Interceptor::Input::ContinueAsNew->new(
        workflow => 'Greet', args => [], headers => {}, kwargs => {});
    my $ok = eval { $ob->continue_as_new($can_input); 1 };
    T2->ok(!$ok && $@ =~ /continue_as_new reached the chain root/,
        'continue_as_new still unwinds to the chain root (headers were injected first)');
    T2->is(scalar @{ $tracer->spans }, $before_span_count,
        'continue_as_new creates NO span');
    my $can_hdr = $ob_seen{continue_as_new}->headers->{'_tracer-data'};
    T2->ok(defined $can_hdr, 'continue_as_new injects the header anyway');
    T2->is($i->_payload_to_carrier($can_hdr)->{traceparent}, $TP1,
        'continue_as_new injects the cached run context (no new span to derive one from)');

    # sub-step 4/5: round-trip check: a downstream ActivityInbound
    # interceptor reading the injected _tracer-data header (same header_key
    # on both sides) sees the OUTBOUND span as its parent.
    my $ai = $i->intercept_activity(RecActivityNext->new(seen => \%seen));
    $ai->execute_activity(
        Temporalio::Worker::Interceptor::Input::ExecuteActivity->new(
            args    => [],
            headers => { '_tracer-data' => $act_hdr },
            info    => { activity_type => 'Downstream' }))->get;
    my $down = $tracer->spans_named('RunActivity:Downstream')->[0];
    T2->is($down->parent->carrier->{traceparent}, $act_spans->[0]->traceparent,
        'a downstream inbound interceptor parents on the outbound span context');
});

# --------------------------------------------------------------------------
# F1 (spec F1, GitHub #6): the end-to-end shape check the I6 linkage test
# could not make, because it handed the outbound fixture's raw header value
# straight to the inbound hook. Here the REAL Runner is driven through the
# replay harness (the reproduction lessons.md 2026-06-26 prescribes for this
# double-encode class), so the injected header goes through
# Temporalio::Interceptor::Headers::to_payload_map on its way into the
# ScheduleActivity command, and the start header arrives at execute_workflow
# as the blessed proto Payload Runner::_apply_initialize threads off the
# InitializeWorkflow job. Decoding the emitted header ONCE with the data
# converter must recover the carrier, which is what a receiving SDK does
# (sdk-python _context_from_headers: from_payloads([header_payload])[0],
# contrib/opentelemetry/_interceptor.py:159-172).
#
# FAILS on HEAD: _carrier_to_payload returns an unblessed { metadata, data }
# hashref, so is_payload is false and to_payload_map JSON-encodes the whole
# hashref as a payload BODY; and _payload_to_carrier requires `ref eq 'HASH'`,
# so the blessed start header extracts nothing and the outbound gate never
# even opens. Observed on HEAD before the fix: "the outbound wrapper created a
# StartActivity span inside the Runner" fails with an undef span, and the
# subtest returns right there, before the header assertion is ever reached,
# because with no span there is no injection to check.
#
# MUTATION CHECK (the R41 convention). Reverting the blessing ALONE, so
# _carrier_to_payload hands back the unblessed { metadata, data } hashref while
# the duck-typed _payload_to_carrier stays in place, isolates the double wrap:
# the span and the header are still produced, only their SHAPE is wrong.
# Observed RED under that mutation, verbatim from prove -lv and trimmed to
# this subtest:
#
#     not ok 8 - F1 replay harness: emitted ScheduleActivity headers ... {
#         ok 5 - the emitted header value is a Payload (true of both shapes ...)
#         not ok 6 - the emitted payload body IS the carrier map, not a
#                    serialized payload hashref
#         not ok 7 - the emitted bytes carry the outbound span traceparent
#                    directly
#         not ok 8 - a single decode yields the carrier map, not a wrapped
#                    payload hashref
#         not ok 9 - the recovered traceparent is the outbound span context
#         1..9
#     }
#
# 6 and 8 are boolean ok() calls, so neither prints a comparison table. 7 and
# 9 are scalar is() calls, and each prints the same one-row table: under the
# wrap the carrier key sits one level down inside the serialized body, so the
# lookup comes back undef.
#
#     # +---------+---------------------------------------------------------+
#     # | GOT     | CHECK                                                   |
#     # +---------+---------------------------------------------------------+
#     # | <UNDEF> | 00-ffffffffffffffff0000000000000020-0000000000000020-01 |
#     # +---------+---------------------------------------------------------+
#
# The CHECK value is the FakeOTel span traceparent. Its span id is that
# package's per-run counter (sprintf '%016x', ++$NEXT_ID in t/lib/FakeOTel.pm),
# so those digits shift if a subtest ahead of this one creates more spans.
#
# Note assertion 5: is_payload stays GREEN under the mutation, because
# to_payload_map encodes the hashref into a Payload of its own. It is kept
# only as a shape guard and its label says so; the body assertions 6-9 are
# what hold the one-decode contract.
# --------------------------------------------------------------------------
T2->subtest('F1 replay harness: emitted ScheduleActivity headers are real Payloads' => sub {
    my $PC     = Temporalio::Converter::Payload->default;
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);

    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCaller',
        interceptors   => [$i],
    );
    my $activation =
        'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    my @cmds = $harness->push_activation($activation->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ActivityCaller',
                arguments     => [ $PC->to_payload('Alice') ],
                headers       => {
                    '_tracer-data' =>
                        $PC->to_payload({ traceparent => $TP1 }),
                },
            } },
        ],
    }));

    my $span = $tracer->spans_named('StartActivity:SayHello')->[0];
    T2->ok(defined $span,
        'the outbound wrapper created a StartActivity span inside the Runner');
    T2->is($span->parent->carrier->{traceparent}, $TP1,
        'the outbound span parents on the blessed start header carrier')
        if defined $span;

    my ($sa) = grep { $_->which_variant eq 'schedule_activity' } @cmds;
    T2->ok(defined $sa, 'the workflow emitted a ScheduleActivity command');
    return unless defined $sa && defined $span;

    my $emitted = ($sa->schedule_activity->headers // {})->{'_tracer-data'};
    T2->ok(defined $emitted,
        'the emitted command carries the _tracer-data header');
    return unless defined $emitted;
    # MUTATION CHECK: is_payload($emitted) on its own survives the double wrap,
    # because to_payload_map hands back a Payload either way (it encodes the
    # unblessed hashref into one). It is kept as a shape guard, with a label
    # that claims only what it proves. What cannot survive the double wrap is
    # the payload BODY: under the wrap those bytes are a serialized
    # { metadata, data } hashref, so the carrier keys are one level down.
    T2->ok(Temporalio::Interceptor::Headers::is_payload($emitted),
        'the emitted header value is a Payload (true of both shapes; body checked below)');
    my $body = eval { JSON::PP->new->utf8->decode($emitted->data) };
    T2->ok(ref $body eq 'HASH'
            && !exists $body->{metadata} && !exists $body->{data},
        'the emitted payload body IS the carrier map, not a serialized payload hashref');
    T2->is($body->{traceparent}, $span->traceparent,
        'the emitted bytes carry the outbound span traceparent directly')
        if ref $body eq 'HASH';

    # ONE decode, exactly as a receiving SDK does.
    my $carrier = $PC->from_payload($emitted);
    T2->ok(ref $carrier eq 'HASH'
            && !exists $carrier->{metadata} && !exists $carrier->{data},
        'a single decode yields the carrier map, not a wrapped payload hashref');
    T2->is($carrier->{traceparent}, $span->traceparent,
        'the recovered traceparent is the outbound span context')
        if ref $carrier eq 'HASH';
});

# --------------------------------------------------------------------------
# F1: the inbound half. A BLESSED wire Payload (what ActivityDispatcher hands
# the chain from the activity Start task's header_fields, and what
# Runner::_apply_initialize hands execute_workflow) must extract to a carrier.
# Payload.pm's POD is explicit that payloads materialized from the wire are
# instances of the generated parent class, so consumers duck-type on the
# metadata/data accessors rather than matching a hashref.
#
# FAILS on HEAD: _payload_to_carrier's `ref $payload eq 'HASH'` guard returns
# undef for any blessed proto Payload, so no parent is extracted and the
# workflow-span gate stays shut. Observed on HEAD: "a blessed wire Payload
# header yields a parent context" fails (parent undef).
# --------------------------------------------------------------------------
T2->subtest('F1 inbound: a blessed wire Payload extracts the parent' => sub {
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);
    my %seen;

    my $ai = $i->intercept_activity(RecActivityNext->new(seen => \%seen));
    $ai->execute_activity(
        Temporalio::Worker::Interceptor::Input::ExecuteActivity->new(
            args    => [],
            headers => { '_tracer-data' =>
                blessed_carrier_payload({ traceparent => $TP1 }) },
            info    => { activity_type => 'Charge' }))->get;
    my $span = $tracer->spans_named('RunActivity:Charge')->[0];
    T2->ok(defined $span && defined $span->parent,
        'a blessed wire Payload header yields a parent context');
    T2->is($span->parent->carrier->{traceparent}, $TP1,
        'the parent is the carrier the blessed Payload carried')
        if defined $span && defined $span->parent;

    # The workflow-inbound side caches the run carrier off the same blessed
    # shape, so the default (parent-present) workflow-span gate opens.
    my $wi = $i->intercept_workflow(RecWorkflowNext->new(seen => \%seen));
    $wi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type    => 'Greet',
            args    => [],
            headers => { '_tracer-data' =>
                blessed_carrier_payload({ traceparent => $TP2 }) }))->get;
    my $run = $tracer->spans_named('RunWorkflow:Greet')->[0];
    T2->ok(defined $run,
        'the workflow-span gate opens off a blessed start header');
    T2->is($run->parent->carrier->{traceparent}, $TP2,
        'the run span parents on the blessed start header carrier')
        if defined $run;

    # The legacy unblessed { metadata, data } shape still decodes: the
    # extractor duck-types rather than switching on one representation.
    T2->is($i->_payload_to_carrier(carrier_payload({ traceparent => $TP3 })),
        { traceparent => $TP3 },
        'the legacy hashref shape still decodes');
});

# --------------------------------------------------------------------------
# F1 sub-steps 4/5: the Headers.pm contract directly. The value
# _carrier_to_payload builds must satisfy is_payload, and to_payload_map must
# pass that exact instance through rather than encoding it a second time
# (#10 GAP B, the double-encode class lessons.md 2026-06-26 records).
#
# FAILS on HEAD: the unblessed hashref fails is_payload, so to_payload_map
# hands it to the JSON converter and the map value is a NEW Payload whose body
# is the serialized hashref.
# --------------------------------------------------------------------------
T2->subtest('F1 to_payload_map passes the injected header payload through' => sub {
    my $PC = Temporalio::Converter::Payload->default;
    my $i  = $TI->new;

    my $payload = $i->_carrier_to_payload({ traceparent => $TP1 });
    T2->ok(Temporalio::Interceptor::Headers::is_payload($payload),
        'the built header value satisfies the Headers.pm is_payload contract');

    my $map = Temporalio::Interceptor::Headers::to_payload_map(
        $PC, { '_tracer-data' => $payload });
    T2->is(Scalar::Util::refaddr($map->{'_tracer-data'}),
        Scalar::Util::refaddr($payload),
        'the same Payload instance rides through: no second encode');
    T2->is($PC->from_payload($map->{'_tracer-data'}),
        { traceparent => $TP1 },
        'one decode off the map recovers the carrier');
});

# --------------------------------------------------------------------------
# F1: the OUTBOUND parent-missing gate (_traced_call). With no run carrier and
# always_create_workflow_spans=0 there is no span and no injection; with =1
# there are both, and the injected carrier is the new parentless span's own
# context. continue_as_new has no span and no gate, but with no carrier there
# is nothing to render, so it writes no header either.
# --------------------------------------------------------------------------
T2->subtest('F1 outbound parent-missing gate' => sub {
    my $start_activity = sub {
        my ($ob, $name) = @_;
        return $ob->execute_activity(
            Temporalio::Worker::Interceptor::Input::StartActivity->new(
                activity => $name, args => [], headers => {}, kwargs => {}));
    };

    # Default: no start header, so no run carrier, so nothing happens.
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);
    my %seen;
    my $wi = $i->intercept_workflow(RecWorkflowNext->new(seen => \%seen));
    $wi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type => 'Greet', args => [], headers => {}))->get;
    my %ob_seen;
    $wi->init(RecOutboundNext->new(seen => \%ob_seen));
    my $ob = $seen{init_outbound};

    $start_activity->($ob, 'Charge');
    T2->is(scalar @{ $tracer->spans_named('StartActivity:Charge') }, 0,
        'no outbound span without a run parent context (default gate)');
    T2->ok(!exists $ob_seen{execute_activity}->headers->{'_tracer-data'},
        'and no header injected either');

    # continue_as_new: no gate, but an absent carrier renders an empty
    # propagator carrier, so _inject_headers writes nothing.
    eval {
        $ob->continue_as_new(
            Temporalio::Worker::Interceptor::Input::ContinueAsNew->new(
                workflow => 'Greet', args => [], headers => {}, kwargs => {}));
        1;
    };
    T2->ok(!exists $ob_seen{continue_as_new}->headers->{'_tracer-data'},
        'continue_as_new injects nothing when the run carrier is absent');

    # always_create_workflow_spans=1: span AND injection, parentless.
    my $tracer2 = FakeOTel::Tracer->new;
    my $i2 = $TI->new(tracer => $tracer2,
        propagator => FakeOTel::Propagator->new,
        always_create_workflow_spans => 1);
    my %seen2;
    my $wi2 = $i2->intercept_workflow(RecWorkflowNext->new(seen => \%seen2));
    $wi2->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type => 'Greet', args => [], headers => {}))->get;
    my %ob_seen2;
    $wi2->init(RecOutboundNext->new(seen => \%ob_seen2));
    my $ob2 = $seen2{init_outbound};

    $start_activity->($ob2, 'Charge');
    my $spans2 = $tracer2->spans_named('StartActivity:Charge');
    T2->is(scalar @$spans2, 1,
        'always_create_workflow_spans=1 creates the outbound span with no parent');
    T2->ok(!defined $spans2->[0]->parent, 'and the span has no parent')
        if @$spans2;
    my $hdr2 = $ob_seen2{execute_activity}->headers->{'_tracer-data'};
    T2->ok(defined $hdr2, 'and injects the header');
    T2->is($i2->_payload_to_carrier($hdr2)->{traceparent},
        $spans2->[0]->traceparent,
        'the injected carrier is the parentless span own context')
        if defined $hdr2 && @$spans2;
});

# --------------------------------------------------------------------------
# I6: workflow-outbound spans no-op while replaying: no span AND no header
# injection (Python _completed_span:699-701 returns before either happens).
# --------------------------------------------------------------------------
T2->subtest('I6 workflow outbound: no-op while replaying' => sub {
    my $tracer = FakeOTel::Tracer->new;
    my $i = $TI->new(tracer => $tracer, propagator => FakeOTel::Propagator->new);
    my %seen;
    my $wi = $i->intercept_workflow(RecWorkflowNext->new(seen => \%seen));
    $wi->execute_workflow(
        Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
            type    => 'Greet',
            args    => [],
            headers => { '_tracer-data' => carrier_payload({ traceparent => $TP1 }) },
        ))->get;

    my %ob_seen;
    $wi->init(RecOutboundNext->new(seen => \%ob_seen));
    my $ob = $seen{init_outbound};

    local $Temporalio::Workflow::Runner::CURRENT = FakeReplayRunner->new;
    $ob->execute_activity(
        Temporalio::Worker::Interceptor::Input::StartActivity->new(
            activity => 'Charge', args => [], headers => {}, kwargs => {}));
    T2->is(scalar @{ $tracer->spans_named('StartActivity:Charge') }, 0,
        'no span created while replaying');
    T2->ok(!exists $ob_seen{execute_activity}->headers->{'_tracer-data'},
        'no header injected while replaying either');

    $ob->start_nexus_operation(
        Temporalio::Worker::Interceptor::Input::StartNexusOperation->new(
            endpoint => 'ep', service => 'svc', operation => 'op',
            input => undef, headers => {}, kwargs => {}));
    T2->is(scalar @{ $tracer->spans_named('StartNexusOperation:svc/op') }, 0,
        'no nexus span while replaying');
    T2->ok(!exists $ob_seen{start_nexus_operation}->headers->{traceparent},
        'no nexus string-header injection while replaying');
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
    T2->is($i->_outbound_span_name('start_nexus_operation', { name => 'svc/op' }),
        'StartNexusOperation:svc/op', 'StartNexusOperation:{service}/{operation}');
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
