# ABOUTME: Unit tests for the user-facing metric meter on activity and Nexus
# ABOUTME: contexts (spec R83, parity activity/conversion + nexus findings):
# ABOUTME: counters reach a test buffer with the context attribute sets
# ABOUTME: (activity.py:247,461; nexus/_operation_context.py:107), per-call
# ABOUTME: attributes merge, and the core-FFI backend round-trips end to end.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Scalar::Util ();
use MetricBuffer ();
use Temporalio::Activity::Context ();
use Temporalio::Cancellation ();
use Temporalio::Converter::Data ();
use Temporalio::Nexus ();
use Temporalio::Nexus::OperationContext ();
use Temporalio::Runtime::MetricMeter ();

# A recording custom-sink meter for the end-to-end subtest: the emission
# surface writes through the CORE meter, core routes to this configured
# exporter, and the drain delivers here (the same TestMeter shape as
# t/unit/metric_meter.t).
package SinkMeter {
    use parent -norequire, 'Temporalio::Runtime::MetricMeter';
    sub new ($class) {
        return bless { created => [], attrs => [], records => [] }, $class;
    }
    sub created ($self) { $self->{created} }
    sub records ($self) { $self->{records} }
    sub create_metric ($self, $name, $desc, $unit, $kind) {
        my $metric = { name => $name, desc => $desc, unit => $unit, kind => $kind };
        push @{ $self->{created} }, $metric;
        return $metric;
    }
    sub new_attributes ($self, $append_from, $attributes) {
        my $base = defined $append_from ? { %{ $append_from } } : {};
        return { %$base, %$attributes };
    }
    sub record_integer ($self, $metric, $value, $attrs) {
        push @{ $self->{records} },
            { kind => 'integer', metric => $metric, value => $value, attrs => $attrs };
    }
    sub record_float ($self, $metric, $value, $attrs) {
        push @{ $self->{records} },
            { kind => 'float', metric => $metric, value => $value, attrs => $attrs };
    }
    sub record_duration ($self, $metric, $value, $attrs) {
        push @{ $self->{records} },
            { kind => 'duration', metric => $metric, value => $value, attrs => $attrs };
    }
}

sub exception_from ($code) {
    return do { local $@; eval { $code->(); 1 } ? undef : $@ };
}

sub buffer_meter () {
    my $buffer = MetricBuffer->new;
    my $meter  = Temporalio::Runtime::MetricMeter::Meter->new(
        backend => $buffer);
    return ($buffer, $meter);
}

# Build an Activity::Context with the minimum this file needs; metric_meter
# rides in as the worker-injected runtime meter (undef = the fork-pool child).
sub make_activity_context (%overrides) {
    return Temporalio::Activity::Context->new(
        info => {
            activity_id       => 'act-1',
            activity_type     => 'SayHello',
            attempt           => 1,
            task_token        => 'token',
            task_queue        => 'act-tq',
            workflow_id       => 'wf-1',
            workflow_run_id   => 'run-1',
            workflow_type     => 'Greeting',
            namespace         => 'act-ns',
            heartbeat_details => [],
        },
        cancellation       => Temporalio::Cancellation->new,
        data_converter     => Temporalio::Converter::Data->new,
        heartbeat_recorder => sub ($bytes) { return undef },
        %overrides,
    );
}

T2->subtest('activity counter reaches the buffer with context attributes' => sub {
    my ($buffer, $meter) = buffer_meter();
    my $ctx = make_activity_context(metric_meter => $meter);

    my $counter = $ctx->metric_meter->create_counter('act_counter');
    $counter->add(2, { flag => 'x' });

    T2->is(scalar @{ $buffer->records }, 1, 'one value recorded');
    my $record = $buffer->records->[0];
    T2->is($record->{value}, 2, 'recorded value');
    T2->is($record->{attrs}, {
        # Python parity: activity.py:461-468 lazily appends these three.
        namespace     => 'act-ns',
        task_queue    => 'act-tq',
        activity_type => 'SayHello',
        flag          => 'x',
    }, 'activity attribute set plus the per-call attribute');

    T2->is(Scalar::Util::refaddr($ctx->metric_meter),
        Scalar::Util::refaddr($ctx->metric_meter),
        'the context meter is memoized');
});

T2->subtest('histogram record and gauge set route through the same wrapper' => sub {
    my ($buffer, $meter) = buffer_meter();
    my $ctx = make_activity_context(metric_meter => $meter);

    $ctx->metric_meter->create_histogram('act_hist', unit => 'ms')->record(7);
    $ctx->metric_meter->create_gauge('act_gauge')->set(3);

    T2->is(scalar @{ $buffer->records }, 2, 'both values recorded');
    T2->is($buffer->records->[0]{kind},
        Temporalio::Runtime::MetricMeter::Kind::HISTOGRAM_INTEGER,
        'create_histogram maps to the HistogramInteger kind');
    T2->is($buffer->records->[0]{value}, 7, 'histogram value');
    T2->is($buffer->records->[1]{kind},
        Temporalio::Runtime::MetricMeter::Kind::GAUGE_INTEGER,
        'create_gauge maps to the GaugeInteger kind');
    T2->is($buffer->records->[1]{value}, 3, 'gauge value');
});

T2->subtest('instrument misuse raises the typed argument error' => sub {
    my (undef, $meter) = buffer_meter();

    my $negative = exception_from(sub {
        $meter->create_counter('neg')->add(-1);
    });
    T2->ok(Scalar::Util::blessed($negative)
            && $negative->isa('Temporalio::Exception::Argument'),
        'a negative value raises Argument (Python parity)')
        or T2->diag('got: ' . ($negative // 'no exception'));

    my $unknown = exception_from(sub {
        $meter->create_counter('bad', bogus_option => 1);
    });
    T2->ok(Scalar::Util::blessed($unknown)
            && $unknown->isa('Temporalio::Exception::Argument'),
        'an unknown create option raises Argument')
        or T2->diag('got: ' . ($unknown // 'no exception'));
});

T2->subtest('fork-pool context without a meter raises' => sub {
    my $ctx = make_activity_context();
    my $err = exception_from(sub { $ctx->metric_meter });
    T2->ok(Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Runtime'),
        'metric_meter without a runtime meter raises (Python parity: '
        . 'non-threaded sync activities)')
        or T2->diag('got: ' . ($err // 'no exception'));
});

T2->subtest('nexus operation context exposes a usable meter' => sub {
    my ($buffer, $meter) = buffer_meter();
    my $info = Temporalio::Nexus::OperationInfo->new(
        service    => 'MySvc',
        operation  => 'my_op',
        endpoint   => 'ep',
        task_queue => 'nexus-tq',
    );
    my $ctx = Temporalio::Nexus::StartOperationContext->new(
        info         => $info,
        metric_meter => $meter,
    );

    # Edge from the plan: per-call attributes merge over the context set.
    $ctx->metric_meter->create_counter('nexus_counter')
        ->add(1, { per_call => 'y' });

    T2->is(scalar @{ $buffer->records }, 1, 'one value recorded');
    T2->is($buffer->records->[0]{attrs}, {
        # Python parity: nexus/_operation_context.py:201-209.
        nexus_service   => 'MySvc',
        nexus_operation => 'my_op',
        task_queue      => 'nexus-tq',
        per_call        => 'y',
    }, 'nexus attribute set plus the per-call attribute');

    # The module helper reads the dynamically-scoped context
    # (nexus/_operation_context.py:107 metric_meter()).
    my $helper_meter = do {
        local $Temporalio::Nexus::CURRENT = $ctx;
        Temporalio::Nexus::metric_meter();
    };
    T2->is(Scalar::Util::refaddr($helper_meter),
        Scalar::Util::refaddr($ctx->metric_meter),
        'Temporalio::Nexus::metric_meter() returns the context meter');

    my $outside = exception_from(sub { Temporalio::Nexus::metric_meter() });
    T2->ok(defined $outside,
        'the module helper outside an operation raises');

    my $bare = Temporalio::Nexus::CancelOperationContext->new(info => $info);
    my $err  = exception_from(sub { $bare->metric_meter });
    T2->ok(Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Runtime'),
        'a context constructed without a meter raises')
        or T2->diag('got: ' . ($err // 'no exception'));
});

# The FFI-backed path: the runtime's user-facing meter writes through the CORE
# meter (temporal_core_metric_meter_new + metric_new + record_integer), core
# routes to the configured custom-sink exporter, and the drain delivers to the
# SinkMeter above. This empirically pins the TemporalCoreMetricOptions and
# TemporalCoreMetricAttribute struct layouts.
T2->subtest('core-backed meter end to end through a custom sink' => sub {
    require IO::Async::Loop;
    require Temporalio::Runtime;
    require Temporalio::Runtime::TelemetryConfig;

    my $sink = SinkMeter->new;
    my $loop = IO::Async::Loop->new;
    my $rt   = Temporalio::Runtime->new(
        telemetry => Temporalio::Runtime::TelemetryConfig->new(
            metrics => $sink),
        loop => $loop,
    );

    my $meter = $rt->metric_meter;
    T2->is(Scalar::Util::refaddr($rt->metric_meter),
        Scalar::Util::refaddr($meter), 'the runtime meter is memoized');

    my $counter = $meter->with_additional_attributes({ base => 'b' })
        ->create_counter('e2e_requests',
            description => 'R83 end to end',
            unit        => 'requests',
        );
    T2->is($counter->name, 'e2e_requests', 'instrument name accessor');
    $counter->add(5, {
        region => 'us-west',
        count  => 2,
        ratio  => 0.5,
    });

    # Creates/attributes marshalled inline (main thread); the aggregated
    # record needs a drain to apply (the metric_meter.t precedent).
    $rt->callback->drain($rt);
    $rt->callback->drain($rt);

    T2->is(scalar @{ $sink->created }, 1, 'the sink saw one metric create');
    my $created = $sink->created->[0];
    T2->is($created->{name}, 'e2e_requests', 'metric name crossed the FFI');
    T2->is($created->{desc}, 'R83 end to end', 'description crossed the FFI');
    T2->is($created->{unit}, 'requests', 'unit crossed the FFI');
    T2->is($created->{kind},
        Temporalio::Runtime::MetricMeter::Kind::COUNTER_INTEGER,
        'counter kind crossed the FFI');

    T2->is(scalar @{ $sink->records }, 1, 'the sink saw one aggregated record');
    my $record = $sink->records->[0];
    T2->is($record->{kind}, 'integer', 'counter adds record integers');
    T2->is($record->{value}, 5, 'value crossed the FFI');
    # A subset match: core's DEFAULT attribute set rides along (it carries
    # service_name => 'temporal-core-sdk'), on top of which our base and
    # per-call attributes append.
    T2->like($record->{attrs}, {
        base   => 'b',
        region => 'us-west',
        count  => 2,
        ratio  => 0.5,
    }, 'string/int/float attributes decode with their types');

    $rt->shutdown;

    # A meterless runtime yields the shared noop meter: emits are safe no-ops.
    my $plain = Temporalio::Runtime->new(loop => IO::Async::Loop->new);
    my $noop  = $plain->metric_meter;
    T2->ok($noop->isa('Temporalio::Runtime::MetricMeter::Meter'),
        'a runtime without metrics still exposes a meter');
    my $ok = eval { $noop->create_counter('nope')->add(1); 1 };
    T2->ok($ok, 'emitting on the noop meter is a safe no-op') or T2->diag($@);
    $plain->shutdown;
});

T2->done_testing;
