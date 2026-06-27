# ABOUTME: Repro + regression for #10 C-ICEPT-ACTIVITY-HEADERS (two gaps): the
# ABOUTME: activity-inbound ExecuteActivity input must carry the activity Start
# ABOUTME: task's header_fields (GAP A), and a header value set at start must
# ABOUTME: round-trip to the inbound hook un-double-encoded (GAP B: the outbound
# ABOUTME: schedule_activity must pass an already-Payload header through, not
# ABOUTME: re-run it through to_payload). Mirrors the workflow-side B11 repro.
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
use IO::Async::Loop ();

use Temporalio::Converter::Data ();
use Temporalio::Converter::Payload ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::ActivityRegistry ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::Interceptor ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Test::WorkflowReplay ();

# An activity-inbound spy that records the execute_activity input's `headers`
# map (the start header_fields the dispatcher must thread in) before delegating
# to the next link. Signature-less methods + the explicit ->new call are
# required under `feature 'class'` + Future::AsyncAwait (see the other inbound
# interceptor tests).
class HeaderSpyActivityInbound :isa(Temporalio::Worker::ActivityInbound) {
    field $seen :param;
    method execute_activity {
        %$seen = ( $_[0]->headers // {} )->%*;
        return $self->next->execute_activity($_[0]);
    }
}
class HeaderSpyInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $seen :param;
    method intercept_activity {
        return HeaderSpyActivityInbound->new(next => $_[0], seen => $seen);
    }
}

class FakeClient {
    field $data_converter :param;
    field $namespace      :param = 'default';
    field $identity       :param = 'pid@host';
    method data_converter { $data_converter }
    method namespace      { $namespace }
    method identity       { $identity }
}

# A stand-in fork pool that runs the sync body inline (no real fork) so the
# dispatcher's sync branch is unit-testable without forking (mirrors the
# FakePool in t/unit/activity_pool.t).
class FakePool {
    method invoke ($inv) { return Future->done("Hi, " . $inv->args->[0]) }
    method close { }
}

my $loop = IO::Async::Loop->new;
sub await_f ($f) { return $f->get }

my $ActivityTask = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityTask');
my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
my $WorkflowExecution = Temporalio::Core::Proto::resolve(
    'temporal.api.common.v1.WorkflowExecution');

# Build an activity Start task carrying a `header_fields` map (proto field 6).
sub start_task_bytes ($dc, $token, $type, $header_fields, @args) {
    my @payloads = await_f($dc->to_payloads([@args]));
    my $start = $Start->new({
        workflow_namespace => 'default',
        workflow_type      => 'GreetWorkflow',
        workflow_execution => $WorkflowExecution->new({
            workflow_id => 'wf-1', run_id => 'run-1' }),
        activity_id   => 'act-1',
        activity_type => $type,
        input         => [@payloads],
        attempt       => 1,
        header_fields => $header_fields,
    });
    return $ActivityTask->new({ task_token => $token, start => $start })->encode;
}

# Dispatch one activity Start carrying header_fields and return the headers map
# the activity-inbound hook saw, for both the sync and async activity branches.
sub seen_headers_for ($sync, $header_fields) {
    my $dc = Temporalio::Converter::Data->new;
    my $fn = $sync
        ? Temporalio::Activity::FunctionDefinition->new(
            name => 'greet', sync => 1, code => sub ($name) { return "Hi, $name" })
        : Temporalio::Activity::FunctionDefinition->new(
            name => 'greet', code => async sub ($name) { return "Hi, $name" });
    my $registry =
        Temporalio::Worker::ActivityRegistry->new(activities => [$fn]);

    my %seen;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        client         => FakeClient->new(data_converter => $dc),
        loop           => $loop,
        pool           => ($sync ? FakePool->new : undef),
        completer      => sub ($bytes) { Future->done },
        interceptors   => [ HeaderSpyInterceptor->new(seen => \%seen) ],
    );

    await_f($dispatcher->dispatch_task(
        start_task_bytes($dc, 'tok-1', 'greet', $header_fields, 'World')));
    return \%seen;
}

# --------------------------------------------------------------------------
# GAP A: the activity-inbound ExecuteActivity input carries the Start task's
# header_fields. Today the dispatcher builds the input with only args/_root, so
# the spy sees an empty header map and this FAILS (#10 GAP A).
# --------------------------------------------------------------------------
T2->subtest('activity-inbound input carries the Start header_fields (async)' => sub {
    my $PC = Temporalio::Converter::Payload->default;
    my $seen = seen_headers_for(0,
        { _request_id => $PC->to_payload('rid-act') });

    T2->ok(exists $seen->{_request_id},
        'the inbound execute_activity input carries the start header key');
    T2->is($PC->from_payload($seen->{_request_id}), 'rid-act',
        'the start header payload decodes (once) to the value set at start')
        if exists $seen->{_request_id};
});

T2->subtest('activity-inbound input carries the Start header_fields (sync)' => sub {
    my $PC = Temporalio::Converter::Payload->default;
    my $seen = seen_headers_for(1,
        { _request_id => $PC->to_payload('rid-act') });

    T2->ok(exists $seen->{_request_id},
        'the sync-branch inbound input also carries the start header key');
    T2->is($PC->from_payload($seen->{_request_id}), 'rid-act',
        'the sync-branch start header payload decodes (once) to the value')
        if exists $seen->{_request_id};
});

# --------------------------------------------------------------------------
# GAP B (round-trip): a header value set at start round-trips to the activity-
# inbound hook un-double-encoded. The workflow forwards an ALREADY-Payload
# header value into execute_activity; the emitted ScheduleActivity command is
# the header_fields the server would deliver to the activity. Feeding it through
# the activity dispatcher, the inbound hook must decode it back to the value
# with a SINGLE from_payload. Today schedule_activity re-runs the Payload
# through to_payload (double-encode), so a single decode yields a blessed
# Payload, not 'rid-act' -> FAILS (#10 GAP B).
# --------------------------------------------------------------------------
T2->subtest('header set at start round-trips to the activity-inbound hook un-double-encoded' => sub {
    my $PC = Temporalio::Converter::Payload->default;

    # Outbound: drive the real Runner schedule_activity through the replay
    # harness; pull the emitted ScheduleActivity command's header payload.
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::HeaderActivityCaller',
    );
    my $activation =
        'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    my @cmds = $harness->push_activation($activation->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'HeaderActivityCaller',
                arguments     => [ $PC->to_payload('Bob') ],
            } },
        ],
    }));

    my ($sa) = grep { $_->which_variant eq 'schedule_activity' } @cmds;
    T2->ok(defined $sa, 'the workflow emitted a ScheduleActivity command');
    my $emitted = $sa->schedule_activity->headers->{_request_id};
    T2->ok(defined $emitted, 'the ScheduleActivity command carries the header');

    # Inbound: feed the emitted header_fields through the activity dispatcher.
    my $seen = seen_headers_for(0, { _request_id => $emitted });

    T2->ok(exists $seen->{_request_id},
        'the activity-inbound hook sees the forwarded header');
    T2->is($PC->from_payload($seen->{_request_id}), 'rid-act',
        'the header round-trips un-double-encoded (single decode == the value)')
        if exists $seen->{_request_id};
});

T2->done_testing;
