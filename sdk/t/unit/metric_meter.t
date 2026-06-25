# ABOUTME: Custom metric meter unit tests (spec section 28.2, T-meter-1..9):
# ABOUTME: config shape, the register/marshal/aggregate pipeline, error paths.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Scalar::Util ();
use FFI::Platypus::Buffer ();
use IO::Async::Loop ();
use Temporalio::Core::FFI ();
use Temporalio::Runtime ();
use Temporalio::Runtime::MetricMeter ();
use Temporalio::Runtime::TelemetryConfig ();

# A recording meter: captures every create_metric / new_attributes /
# record_* the shim drives, so the tests can assert the full pipeline. Metric
# handles are plain hashrefs; record_* push onto a shared list.
package TestMeter {
    use parent -norequire, 'Temporalio::Runtime::MetricMeter';
    sub new ($class) {
        return bless { created => [], attrs => [], records => [] }, $class;
    }
    sub created  ($self) { $self->{created} }
    sub records  ($self) { $self->{records} }
    sub attrs    ($self) { $self->{attrs} }
    sub create_metric ($self, $name, $desc, $unit, $kind) {
        my $metric = { name => $name, desc => $desc, unit => $unit, kind => $kind };
        push @{ $self->{created} }, $metric;
        return $metric;    # opaque handle
    }
    sub new_attributes ($self, $append_from, $attributes) {
        my $set = { append_from => $append_from, attrs => $attributes };
        push @{ $self->{attrs} }, $set;
        return $set;
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

# A meter whose create_metric throws, to prove a throwing method never unwinds
# across the C ABI (T-meter-8) — the disabled handle just returns 0.
package ThrowingMeter {
    use parent -norequire, 'Temporalio::Runtime::MetricMeter';
    sub new ($class) { return bless {}, $class }
    sub create_metric ($self, @) { die "boom in create_metric\n" }
}

my $ffi = Temporalio::Core::FFI::ffi();

# Build a callable from one of the shim's callback pointers. The eight meter
# callbacks are invoked BY CORE; here we drive them from Perl on the main
# thread (the inline marshalling path) to exercise the whole pipeline without
# a live worker.
sub shim_fn ($ptr, $args, $ret) {
    return $ffi->function($ptr => $args => $ret);
}

sub baref ($s) {
    my ($d, $sz) = FFI::Platypus::Buffer::scalar_to_buffer($s);
    return Temporalio::Core::FFI::ByteArrayRef->new(data => $d, size => $sz);
}

# Drive the shim's callbacks on the main thread through a registered runtime.
sub with_meter_runtime ($meter, $code) {
    my $loop = IO::Async::Loop->new;
    my $rt = Temporalio::Runtime->new(
        telemetry => Temporalio::Runtime::TelemetryConfig->new(metrics => $meter),
        loop      => $loop,
    );
    my $ok  = eval { $code->($rt); 1 };
    my $err = $@;
    $rt->shutdown;
    die $err unless $ok;
    return;
}

# --- T-meter-1: config builds custom_meter, others NULL -----------------------

T2->subtest('T-meter-1 config sets custom_meter, others NULL' => sub {
    my $meter = TestMeter->new;
    my $telemetry = Temporalio::Runtime::TelemetryConfig->new(metrics => $meter);
    T2->is($telemetry->custom_meter, $meter, 'custom_meter accessor returns the meter');

    my @keep;
    my $opts = $telemetry->to_ffi(\@keep);
    T2->ok(defined scalar $opts->metrics, 'telemetry carries a metrics options pointer');
    my $metrics = $ffi->cast(
        'opaque' => 'record(Temporalio::Core::FFI::MetricsOptions)*', scalar $opts->metrics);
    T2->ok(scalar $metrics->custom_meter, 'custom_meter pointer is non-NULL');
    T2->ok(!scalar $metrics->opentelemetry, 'opentelemetry is NULL');
    T2->ok(!scalar $metrics->prometheus,    'prometheus is NULL');

    my $cm = $ffi->cast(
        'opaque' => 'record(Temporalio::Core::FFI::CustomMetricMeter)*',
        scalar $metrics->custom_meter);
    T2->ok(scalar $cm->metric_new,            'metric_new pointer set');
    T2->ok(scalar $cm->metric_record_integer, 'metric_record_integer pointer set');
    T2->ok(scalar $cm->attributes_new,        'attributes_new pointer set');
    T2->ok(scalar $cm->meter_free,            'meter_free pointer set');
});

# --- T-meter-2: meter + Prometheus -> Argument --------------------------------

T2->subtest('T-meter-2 meter + Prometheus is Argument' => sub {
    require Temporalio::Runtime::PrometheusConfig;
    my $meter = TestMeter->new;
    my $prom  = Temporalio::Runtime::PrometheusConfig->new(
        bind_address => '127.0.0.1:0');
    my $err = do {
        local $@;
        eval {
            Temporalio::Runtime::TelemetryConfig->new(metrics => [ $meter, $prom ]);
        };
        $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        'two exporters (meter + Prometheus) raises Argument',
    ) or T2->diag('got: ' . ($err // 'no exception'));
});

# --- T-meter-3..6: the live register/marshal/aggregate pipeline ---------------

T2->subtest('T-meter-3..6 pipeline create/record/attributes' => sub {
    my $meter = TestMeter->new;
    with_meter_runtime($meter, sub ($rt) {
        my $metric_new = shim_fn(
            Temporalio::Core::FFI::meter_metric_new_ptr(),
            [ 'TemporalCoreByteArrayRef', 'TemporalCoreByteArrayRef',
              'TemporalCoreByteArrayRef', 'sint32' ],
            'opaque');

        my $name = 'temporal_requests';
        my $unit = 'requests';
        my $kind = Temporalio::Runtime::MetricMeter::Kind::COUNTER_INTEGER;
        # metric_new returns a handle id immediately (shim-allocated), parking
        # a create request the drain runs.
        my $h1 = $metric_new->(baref($name), baref(''), baref($unit), $kind);
        T2->ok($h1, 'metric_new returns a non-NULL handle');

        # T-meter-3: a second create returns a DISTINCT handle (one metric_new
        # per metric); identity preserved across records below.
        my $h2 = $metric_new->(baref('other'), baref(''), baref(''), $kind);
        T2->isnt($h1, $h2, 'distinct metrics get distinct handles (T-meter-3)');

        # attributes_new (T-meter-5: decode a string attribute).
        my $attrs_new = shim_fn(
            Temporalio::Core::FFI::meter_attributes_new_ptr(),
            [ 'opaque', 'opaque', 'size_t' ], 'opaque');
        my $key = 'region';
        my $val = 'us-west-2';
        my ($kd, $ks) = FFI::Platypus::Buffer::scalar_to_buffer($key);
        my ($vd, $vs) = FFI::Platypus::Buffer::scalar_to_buffer($val);
        # TemporalCoreCustomMetricAttribute: key(ptr,size) + value union
        # {string {ptr,size}} + value_type(1=String), padded to 40 bytes.
        my $attr = pack('Q Q Q Q l x4', $kd, $ks, $vd, $vs, 1);
        my ($attr_ptr, $attr_len) = FFI::Platypus::Buffer::scalar_to_buffer($attr);
        my $a1 = $attrs_new->(undef, $attr_ptr, 1);
        T2->ok($a1, 'attributes_new returns a non-NULL handle');

        # Drain binds the parked create requests to the meter (the shim signalled
        # the fd; a direct drain is deterministic for the unit test).
        $rt->callback->drain($rt);

        T2->is(scalar @{ $meter->created }, 2, 'create_metric called once per metric');
        T2->is($meter->created->[0]{name}, $name, 'metric name decoded');
        T2->is($meter->created->[0]{unit}, $unit, 'metric unit decoded');
        T2->is($meter->created->[0]{kind}, $kind, 'metric kind decoded');
        T2->is(scalar @{ $meter->attrs }, 1, 'new_attributes called once');
        T2->is($meter->attrs->[0]{attrs}{region}, 'us-west-2',
            'string attribute decoded (T-meter-5)');

        # record_integer + record_float aggregate in the shim; a second drain
        # applies them to the now-bound handles (T-meter-4).
        my $rec_int = shim_fn(
            Temporalio::Core::FFI::meter_record_integer_ptr(),
            [ 'opaque', 'uint64', 'opaque' ], 'void');
        my $rec_flt = shim_fn(
            Temporalio::Core::FFI::meter_record_float_ptr(),
            [ 'opaque', 'double', 'opaque' ], 'void');
        $rec_int->($h1, 3, $a1);
        $rec_int->($h1, 4, $a1);   # same (metric,attrs) bucket -> sums to 7
        $rec_flt->($h2, 1.5, undef);

        $rt->callback->drain($rt);

        my @int = grep { $_->{kind} eq 'integer' } @{ $meter->records };
        my @flt = grep { $_->{kind} eq 'float' }   @{ $meter->records };
        T2->is(scalar @int, 1, 'integer records aggregate into one bucket (T-meter-4)');
        T2->is($int[0]{value}, 7, 'aggregated integer value summed exactly (3+4)');
        T2->is($int[0]{metric}{name}, $name,
            'record routed to the right metric (identity, T-meter-3)');
        T2->is($int[0]{attrs}{attrs}{region}, 'us-west-2',
            'record carries the attribute set (T-meter-6)');
        T2->is(scalar @flt, 1, 'float record applied');
        T2->is($flt[0]{value}, 1.5, 'float value preserved');
    });
});

T2->subtest('T-meter-8 throwing create_metric does not unwind' => sub {
    my $meter = ThrowingMeter->new;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $h;
    with_meter_runtime($meter, sub ($rt) {
        my $metric_new = shim_fn(
            Temporalio::Core::FFI::meter_metric_new_ptr(),
            [ 'TemporalCoreByteArrayRef', 'TemporalCoreByteArrayRef',
              'TemporalCoreByteArrayRef', 'sint32' ],
            'opaque');
        # The shim allocates and returns the id immediately; create_metric
        # throws only when the drain runs the parked request. The throw is
        # caught (no unwind across the C ABI), the handle bound to disabled, and
        # a warn emitted. A record to the disabled handle then drops.
        $h = $metric_new->(baref('x'), baref(''), baref(''), 1);
        T2->ok($ffi->cast('opaque' => 'uint64', $h),
            'metric_new returns a (shim-allocated) handle id');
        $rt->callback->drain($rt);    # runs the throwing create_metric
        my $rec_int = shim_fn(
            Temporalio::Core::FFI::meter_record_integer_ptr(),
            [ 'opaque', 'uint64', 'opaque' ], 'void');
        $rec_int->($h, 9, undef);
        $rt->callback->drain($rt);    # the disabled handle drops its record
    });
    T2->ok((grep { /threw/ } @warnings),
        'the throw is warned, not propagated (no unwind across the C ABI)');
});

T2->subtest('T-meter-9 meter_free clears handles, no leak' => sub {
    my $meter = TestMeter->new;
    with_meter_runtime($meter, sub ($rt) {
        T2->ok(defined Temporalio::Runtime::MetricMeter->active,
            'meter active during the runtime');
    });
    T2->ok(!defined Temporalio::Runtime::MetricMeter->active,
        'meter cleared after shutdown (T-meter-9)');
});

T2->subtest('second meter runtime is Argument' => sub {
    my $loop = IO::Async::Loop->new;
    my $rt1 = Temporalio::Runtime->new(
        telemetry => Temporalio::Runtime::TelemetryConfig->new(metrics => TestMeter->new),
        loop      => $loop,
    );
    my $err = do {
        local $@;
        eval {
            Temporalio::Runtime->new(
                telemetry => Temporalio::Runtime::TelemetryConfig->new(metrics => TestMeter->new),
                loop      => $loop,
            );
        };
        $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        'a second custom-meter runtime raises Argument',
    ) or T2->diag('got: ' . ($err // 'no exception'));
    $rt1->shutdown;
});

T2->done_testing;
