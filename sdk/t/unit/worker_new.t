# ABOUTME: Unit tests for Temporalio::Worker construction (spec section 8.1,
# ABOUTME: T-wkr-1): registry population + kwargs -> WorkerOptions echo (P0.10).
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Scalar::Util ();
use Temporalio::Core::FFI ();
use Temporalio::Worker ();
use Temporalio::Activity::FunctionDefinition ();

# A worker needs a client (for namespace/identity) and the namespace flows
# from the client into the WorkerOptions. Build a fake just rich enough for
# construction — no live connection, no server. The Worker only reads
# namespace + identity off it during option building.
class FakeClient {
    field $namespace :param = 'default';
    field $identity  :param = 'pid@host';
    method namespace { $namespace }
    method identity  { $identity }
}

# Echo the WorkerOptions struct through the shim debug function (same path as
# worker_options_marshal.t): build a pointer Perl-side, parse the field=value
# summary into a hashref.
sub echo_options ($ptr) {
    my $raw = Temporalio::Core::FFI::debug_worker_options($ptr);
    defined $raw or T2->bail_out('debug_worker_options returned NULL');
    my $summary = Temporalio::Core::FFI::ffi()->cast('opaque' => 'string', $raw);
    Temporalio::Core::FFI::string_free($raw);
    return {
        map { my ($k, $v) = split /=/, $_, 2; ($k => $v) }
        split /\n/, $summary,
    };
}

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

T2->subtest('Worker->new populates the activity registry (T-wkr-1)' => sub {
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'send_email',
        code => sub { 'sent' },
    );
    my $worker = Temporalio::Worker->new(
        client     => FakeClient->new,
        task_queue => 'demo',
        activities => [$fn],
    );
    T2->isa_ok($worker, 'Temporalio::Worker');
    T2->is($worker->task_queue, 'demo', 'task_queue accessor');

    my $reg = $worker->activity_registry;
    T2->isa_ok($reg, 'Temporalio::Worker::ActivityRegistry');
    my $def = $reg->definition('send_email');
    T2->ok(defined $def, 'send_email registered in the activity registry');
    T2->is($def->{code}->(), 'sent', 'registered callable is the function code');
});

T2->subtest('an empty task_queue raises Argument' => sub {
    my $err = exception_from(sub {
        Temporalio::Worker->new(client => FakeClient->new, task_queue => '');
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        'empty task_queue is an Argument exception',
    ) or T2->diag('got: ' . ($err // 'no exception'));
});

T2->subtest('a missing client raises Argument' => sub {
    my $err = exception_from(sub {
        Temporalio::Worker->new(task_queue => 'demo');
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        'missing client is an Argument exception',
    ) or T2->diag('got: ' . ($err // 'no exception'));
});

T2->subtest('default kwargs -> WorkerOptions echo field-for-field (spec 8.1)' => sub {
    my $worker = Temporalio::Worker->new(
        client     => FakeClient->new(namespace => 'ns-a', identity => 'id-a'),
        task_queue => 'tq-a',
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'a', code => sub { }),
        ],
    );
    my $keep = [];
    my $ptr  = $worker->_build_worker_options($keep);
    my $echoed = echo_options($ptr);

    # build_id default (spec §29.1 WH-5): with no build_id kwarg the worker
    # synthesizes the None{build_id} as an MD5 hex of the sorted %INC — a
    # 32-char lowercase hex string (the exact bytes depend on which modules are
    # loaded). Assert the shape, then drop it before the field-for-field match.
    T2->like(delete $echoed->{'versioning_strategy.none.build_id'},
        qr/^[0-9a-f]{32}$/,
        'default build_id is an MD5 hex of %INC (spec §29.1 WH-5)');

    # Defaults verified against sdk-ruby worker.rb (lines 447-465) and the
    # FixedSize tuner default of 100 (tuner.rb 266-269): max_cached_workflows
    # 1000, all slots 100, sticky 10s, heartbeat 60/30s, graceful 0, poller
    # simple_maximum 5, nonsticky_to_sticky_poll_ratio 0.2; versioning
    # None{build_id=MD5(%INC)}; workflows + remote activities enabled, local +
    # nexus disabled (spec 8.1).
    T2->is($echoed, {
        'namespace'                          => 'ns-a',
        'task_queue'                         => 'tq-a',
        'versioning_strategy.tag'            => 'None',
        'identity_override'                  => '<null>',
        'max_cached_workflows'               => '1000',
        'tuner.workflow_slot_supplier'       => 'FixedSize(100)',
        'tuner.activity_slot_supplier'       => 'FixedSize(100)',
        'tuner.local_activity_slot_supplier' => 'FixedSize(100)',
        'tuner.nexus_task_slot_supplier'     => 'FixedSize(100)',
        'task_types.enable_workflows'        => 'true',
        'task_types.enable_local_activities' => 'false',
        'task_types.enable_remote_activities' => 'true',
        'task_types.enable_nexus'            => 'false',
        'sticky_queue_schedule_to_start_timeout_millis' => '10000',
        'max_heartbeat_throttle_interval_millis'        => '60000',
        'default_heartbeat_throttle_interval_millis'    => '30000',
        'max_activities_per_second'            => '0',
        'max_task_queue_activities_per_second' => '0',
        'graceful_shutdown_period_millis'      => '0',
        'workflow_task_poller_behavior'  => 'simple_maximum(5)',
        'nonsticky_to_sticky_poll_ratio' => '0.2',
        'activity_task_poller_behavior'  => 'simple_maximum(5)',
        'nexus_task_poller_behavior'     => 'simple_maximum(5)',
        'nondeterminism_as_workflow_fail' => 'false',
        'nondeterminism_as_workflow_fail_for_types' => '[]',
        'plugins'         => '[]',
        'storage_drivers' => '[]',
    }, 'every echoed default field matches spec 8.1');
});

T2->subtest('explicit kwargs map onto WorkerOptions (spec 8.1)' => sub {
    my $worker = Temporalio::Worker->new(
        client     => FakeClient->new(namespace => 'ns-b', identity => 'id-b'),
        task_queue => 'tq-b',
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'a', code => sub { }),
        ],
        build_id                          => 'build-2026',
        identity_override                 => 'worker-7@host',
        max_cached_workflows              => 42,
        max_concurrent_workflow_tasks     => 7,
        max_concurrent_activities         => 11,
        max_concurrent_local_activities   => 13,
        sticky_queue_schedule_to_start_timeout => 5,
        max_heartbeat_throttle_interval   => 90,
        default_heartbeat_throttle_interval => 15,
        max_activities_per_second         => 1.5,
        max_task_queue_activities_per_second => 2.25,
        graceful_shutdown_period          => 3,
        nondeterminism_as_workflow_fail   => 1,
        workflow_failure_exception_types  => [ 'My::Err', 'Other::Err' ],
    );
    my $keep = [];
    my $echoed = echo_options($worker->_build_worker_options($keep));

    T2->is($echoed->{'namespace'}, 'ns-b', 'namespace from client');
    T2->is($echoed->{'versioning_strategy.none.build_id'}, 'build-2026',
        'build_id -> versioning None{build_id}');
    T2->is($echoed->{'identity_override'}, 'worker-7@host',
        'identity_override passed through (not client identity)');
    T2->is($echoed->{'max_cached_workflows'}, '42', 'max_cached_workflows');
    T2->is($echoed->{'tuner.workflow_slot_supplier'}, 'FixedSize(7)',
        'max_concurrent_workflow_tasks -> workflow FixedSize');
    T2->is($echoed->{'tuner.activity_slot_supplier'}, 'FixedSize(11)',
        'max_concurrent_activities -> activity FixedSize');
    T2->is($echoed->{'tuner.local_activity_slot_supplier'}, 'FixedSize(13)',
        'max_concurrent_local_activities -> local activity FixedSize');
    T2->is($echoed->{'sticky_queue_schedule_to_start_timeout_millis'}, '5000',
        'sticky timeout seconds -> millis');
    T2->is($echoed->{'max_heartbeat_throttle_interval_millis'}, '90000',
        'max heartbeat throttle seconds -> millis');
    T2->is($echoed->{'default_heartbeat_throttle_interval_millis'}, '15000',
        'default heartbeat throttle seconds -> millis');
    T2->is($echoed->{'max_activities_per_second'}, '1.5',
        'max_activities_per_second');
    T2->is($echoed->{'max_task_queue_activities_per_second'}, '2.25',
        'max_task_queue_activities_per_second');
    T2->is($echoed->{'graceful_shutdown_period_millis'}, '3000',
        'graceful_shutdown_period seconds -> millis');
    T2->is($echoed->{'nondeterminism_as_workflow_fail'}, 'true',
        'nondeterminism_as_workflow_fail');
    # spec R14+R15 (finding A1): workflow_failure_exception_types holds Perl
    # EXCEPTION class names routed to live Runners; core's fail-for-types field
    # is a set of WORKFLOW TYPE names (sdk-python fills it from per-definition
    # failure_exception_types, unsupported here) and stays empty. This
    # assertion previously pinned the misroute ('[My::Err,Other::Err]').
    T2->is($echoed->{'nondeterminism_as_workflow_fail_for_types'}, '[]',
        'exception classes are NOT packed into core\'s workflow-TYPE field');
});

T2->subtest('an unknown kwarg raises Argument' => sub {
    my $err = exception_from(sub {
        Temporalio::Worker->new(
            client     => FakeClient->new,
            task_queue => 'demo',
            bogus_kwarg => 1,
        );
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        'unknown kwarg is an Argument exception',
    ) or T2->diag('got: ' . ($err // 'no exception'));
    T2->like("$err", qr/bogus_kwarg/, 'message names the bad kwarg')
        if Scalar::Util::blessed($err);
});

T2->done_testing;
