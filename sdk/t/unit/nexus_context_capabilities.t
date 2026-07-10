# ABOUTME: Unit tests for the restored Nexus handler-context capabilities
# ABOUTME: (spec R89, nexus finding 4): OperationInfo->namespace, the worker-
# ABOUTME: shutdown flag flipped by the dispatcher at shutdown-begin, and the
# ABOUTME: wait_for_worker_shutdown / wait_for_worker_shutdown_sync waiters.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Scalar::Util ();

use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Nexus ();
use Temporalio::Worker::NexusRegistry ();
use Temporalio::Worker::NexusDispatcher ();

require NexusDef::ContextCaps;

# Futures here resolve synchronously (in-memory converter), so ->get drives
# them. Matches nexus_dispatch.t.
sub await_f ($f) { return $f->get }

sub exception_from ($code) {
    return do { local $@; eval { $code->(); 1 } ? undef : $@ };
}

my $NexusTask           = Temporalio::Core::Proto::resolve('coresdk.nexus.NexusTask');
my $NexusTaskCompletion = Temporalio::Core::Proto::resolve('coresdk.nexus.NexusTaskCompletion');
my $PollResp = Temporalio::Core::Proto::resolve(
    'temporal.api.workflowservice.v1.PollNexusTaskQueueResponse');
my $Request  = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.Request');
my $StartReq = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.StartOperationRequest');

# Build a NexusTask `task` variant carrying a start_operation request.
sub start_task_bytes ($dc, $token, $operation, $input) {
    my ($payload) = await_f($dc->to_payloads([$input]));
    my $start = $StartReq->new({
        service => 'caps-service', operation => $operation, payload => $payload });
    my $req  = $Request->new({ start_operation => $start });
    my $poll = $PollResp->new({ task_token => $token, request => $req });
    return $NexusTask->new({ task => $poll, endpoint => 'caps-endpoint' })->encode;
}

sub build_dispatcher (%args) {
    my $dc       = Temporalio::Converter::Data->new;
    my $registry = Temporalio::Worker::NexusRegistry->new(
        nexus_services => ['NexusDef::ContextCaps']);
    my $completions = [];
    my $dispatcher = Temporalio::Worker::NexusDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'caps-tq',
        namespace      => $args{namespace} // 'caps-ns',
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
    );
    return ($dispatcher, $dc, $completions);
}

# Decode the Sync{payload} value out of a NexusTaskCompletion.
sub sync_payload_value ($dc, $bytes) {
    my $c = $NexusTaskCompletion->decode($bytes);
    my ($value) = await_f($dc->from_payloads(
        [$c->completed->start_operation->sync_success->payload]));
    return $value;
}

# R89: OperationInfo carries the worker namespace, matching Python's
# Info.namespace (nexus/_operation_context.py:85, built from the worker's
# namespace in worker/_nexus.py:258-266,398-405).
T2->subtest('R89: OperationInfo->namespace is the worker namespace' => sub {
    my ($d, $dc, $comps) = build_dispatcher(namespace => 'ns-unit');
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-ns', 'echo-namespace', 'x')));
    T2->is(scalar(@$comps), 1, 'one completion sent');
    T2->is(sync_payload_value($dc, $comps->[0]), 'ns-unit|ns-unit',
        'the context info and the module helper both report the namespace');
});

# R89: is_worker_shutdown is false before shutdown and flips true once the
# dispatcher enters shutdown drain; a parked wait_for_worker_shutdown resolves.
T2->subtest('R89: shutdown flip resolves wait_for_worker_shutdown' => sub {
    local $Temporalio::Nexus::IS_WORKER_SHUTDOWN = 0;
    my ($d, $dc, $comps) = build_dispatcher();

    my $dispatch_f = $d->dispatch_task(
        start_task_bytes($dc, 'tok-w', 'wait-shutdown', 'x'));
    T2->ok(!$dispatch_f->is_ready, 'the operation parks awaiting shutdown');
    T2->is($NexusDef::ContextCaps::OBSERVED->{before}, 0,
        'is_worker_shutdown is false inside the operation before shutdown');
    T2->ok(!Temporalio::Nexus::is_worker_shutdown(),
        'the module-level flag is false before shutdown');
    T2->is(scalar(@$comps), 0, 'no completion before shutdown');

    $d->notify_shutdown;
    $d->notify_shutdown;    # idempotent

    T2->ok(Temporalio::Nexus::is_worker_shutdown(),
        'is_worker_shutdown flips true at shutdown-begin');
    T2->ok($dispatch_f->is_ready, 'the parked operation resolves');
    T2->is($NexusDef::ContextCaps::OBSERVED->{after}, 1,
        'the resumed handler observes worker shutdown');
    T2->is(scalar(@$comps), 1, 'the drained operation still completes');
    T2->is(sync_payload_value($dc, $comps->[0]), 'shutdown-observed',
        'the waiter resolution flows into the completion');
});

# R89: the sync variant returns true immediately once shutdown has begun.
T2->subtest('R89: wait_for_worker_shutdown_sync after shutdown-begin' => sub {
    local $Temporalio::Nexus::IS_WORKER_SHUTDOWN = 0;
    my ($d, $dc, $comps) = build_dispatcher();
    $d->notify_shutdown;
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-s', 'sync-wait', 'x')));
    T2->is(sync_payload_value($dc, $comps->[0]), 'sync-wait:1',
        'the sync variant returns true without blocking once shutdown began');
});

# R89 edge: the sync variant blocks up to its timeout, then returns false when
# shutdown never begins (threading.Event.wait(timeout) semantics).
T2->subtest('R89: wait_for_worker_shutdown_sync times out false' => sub {
    local $Temporalio::Nexus::IS_WORKER_SHUTDOWN = 0;
    my ($d, $dc, $comps) = build_dispatcher();
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-t', 'sync-wait-timeout', 'x')));
    T2->is(sync_payload_value($dc, $comps->[0]), 'sync-wait:0',
        'the sync variant returns false after its timeout expires');
});

# R89 edge: the waiters raise outside an operation (Python parity: RuntimeError
# from _temporal_context()); is_worker_shutdown never raises.
T2->subtest('R89: contract outside an operation' => sub {
    local $Temporalio::Nexus::IS_WORKER_SHUTDOWN = 0;
    my $err = exception_from(sub { Temporalio::Nexus::wait_for_worker_shutdown() });
    T2->ok(Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Runtime'),
        'wait_for_worker_shutdown raises outside an operation')
        or T2->diag('got: ' . ($err // 'no exception'));
    my $err_sync = exception_from(
        sub { Temporalio::Nexus::wait_for_worker_shutdown_sync() });
    T2->ok(Scalar::Util::blessed($err_sync)
            && $err_sync->isa('Temporalio::Exception::Runtime'),
        'wait_for_worker_shutdown_sync raises outside an operation')
        or T2->diag('got: ' . ($err_sync // 'no exception'));
    T2->ok(!Temporalio::Nexus::is_worker_shutdown(),
        'is_worker_shutdown stays false and never raises outside an operation');
});

T2->done_testing;
