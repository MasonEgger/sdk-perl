# ABOUTME: Unbound-record and warn-rate-limit tests for the custom metric
# ABOUTME: meter (finding L28 / spec R60): records buffer until bound, never drop.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use FFI::Platypus::Buffer ();
use IO::Async::Loop ();
use Temporalio::Core::FFI ();
use Temporalio::Runtime ();
use Temporalio::Runtime::MetricMeter ();
use Temporalio::Runtime::TelemetryConfig ();

# A recording meter (same shape as metric_meter.t's TestMeter): captures every
# create_metric / record_* so the tests can assert what applied vs dropped.
package RecordingMeter {
    use parent -norequire, 'Temporalio::Runtime::MetricMeter';
    sub new ($class) { return bless { created => [], records => [] }, $class }
    sub created ($self) { $self->{created} }
    sub records ($self) { $self->{records} }
    sub create_metric ($self, $name, $desc, $unit, $kind) {
        my $metric = { name => $name, kind => $kind };
        push @{ $self->{created} }, $metric;
        return $metric;
    }
    sub record_integer ($self, $metric, $value, $attrs) {
        push @{ $self->{records} },
            { kind => 'integer', metric => $metric, value => $value, attrs => $attrs };
    }
    sub record_float    ($self, @) { }
    sub record_duration ($self, @) { }
    sub new_attributes  ($self, $append_from, $attrs) { return $attrs }
}

# record_integer always throws: drives the _apply_record catch + warn site.
package ThrowingRecordMeter {
    use parent -norequire, 'Temporalio::Runtime::MetricMeter';
    sub new ($class) { return bless { attempts => 0 }, $class }
    sub attempts ($self) { $self->{attempts} }
    sub create_metric  ($self, @) { return {} }
    sub record_integer ($self, @) { $self->{attempts}++; die "boom in record_integer\n" }
    sub new_attributes ($self, @) { return {} }
}

# create_metric always throws: drives the _run_request catch + warn site.
package ThrowingCreateMeter {
    use parent -norequire, 'Temporalio::Runtime::MetricMeter';
    sub new ($class) { return bless {}, $class }
    sub create_metric ($self, @) { die "boom in create_metric\n" }
}

my $ffi = Temporalio::Core::FFI::ffi();

sub shim_fn ($ptr, $args, $ret) {
    return $ffi->function($ptr => $args => $ret);
}

sub baref ($s) {
    my ($d, $sz) = FFI::Platypus::Buffer::scalar_to_buffer($s);
    return Temporalio::Core::FFI::ByteArrayRef->new(data => $d, size => $sz);
}

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

# --- R60: create + record + free between wakeups loses nothing ----------------
#
# The shim parks requests FIFO and aggregates records separately; the drain
# services requests before records. Without deferred frees, a create/record/
# free burst between two wakeups binds then immediately deletes the handle, and
# the records drain then finds the id absent and drops the value, contradicting
# the "never dropping a record" contract (Callback.pm drain doc, shim lib.rs
# registry doc). The free must apply only after the record drain.

T2->subtest('R60 record survives create+record+free in one drain cycle' => sub {
    my $meter = RecordingMeter->new;
    with_meter_runtime($meter, sub ($rt) {
        my $metric_new = shim_fn(
            Temporalio::Core::FFI::meter_metric_new_ptr(),
            [ 'TemporalCoreByteArrayRef', 'TemporalCoreByteArrayRef',
              'TemporalCoreByteArrayRef', 'sint32' ],
            'opaque');
        my $rec_int = shim_fn(
            Temporalio::Core::FFI::meter_record_integer_ptr(),
            [ 'opaque', 'uint64', 'opaque' ], 'void');
        my $metric_free = shim_fn(
            Temporalio::Core::FFI::meter_metric_free_ptr(),
            [ 'opaque' ], 'void');

        my $kind = Temporalio::Runtime::MetricMeter::Kind::COUNTER_INTEGER;
        my $h = $metric_new->(baref('burst'), baref(''), baref(''), $kind);
        T2->ok($h, 'metric_new returns a handle id');
        $rec_int->($h, 5, undef);
        $metric_free->($h);

        # One drain sees the create, the record, and the free together.
        $rt->callback->drain($rt);

        T2->is(scalar @{ $meter->created }, 1, 'create_metric ran');
        T2->is(scalar @{ $meter->records }, 1,
            'the record recorded before the free is applied, not dropped');
        T2->is($meter->records->[0]{value}, 5, 'aggregated value intact');
        T2->is($meter->records->[0]{metric}{name}, 'burst',
            'record routed to the created metric handle');
    });
});

# --- R60: a record drained before its create binds buffers, then applies ------
#
# The cross-cycle race: a core thread can park a create AFTER the drain's
# requests loop finished but record BEFORE the records drain snapshots, so
# _apply_record sees an id absent from %METRIC. The record must buffer (no
# warn) and apply once the bind lands (_flush_pending runs after the next
# requests loop). White-box: the bind is simulated by poking %METRIC the way
# _dispatch_request's _REQ_METRIC_NEW arm does.

T2->subtest('R60 unbound record buffers until the bind, then applies' => sub {
    my $meter = RecordingMeter->new;
    Temporalio::Runtime::MetricMeter->_set_active($meter);

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    Temporalio::Runtime::MetricMeter->_apply_record({
        metric_id     => 41,
        attributes_id => 0,
        record_kind   => 1,
        value         => 3,
        count         => 1,
    });
    T2->is(scalar @{ $meter->records }, 0,
        'record for a not-yet-bound id is not applied early');
    T2->is(scalar @warnings, 0, 'buffering an unbound record does not warn');

    # The bind lands (next cycle's requests loop); the flush applies the buffer.
    my $handle = { name => 'late-bind' };
    $Temporalio::Runtime::MetricMeter::METRIC{41} = $handle;
    Temporalio::Runtime::MetricMeter->_flush_pending;

    T2->is(scalar @{ $meter->records }, 1, 'buffered record applied on bind');
    T2->is($meter->records->[0]{value}, 3, 'buffered value intact');
    T2->is($meter->records->[0]{metric}, $handle,
        'buffered record routed to the bound handle');

    # A disabled bind (create_metric returned undef) still drops its buffer.
    Temporalio::Runtime::MetricMeter->_apply_record({
        metric_id     => 42,
        attributes_id => 0,
        record_kind   => 1,
        value         => 9,
        count         => 1,
    });
    $Temporalio::Runtime::MetricMeter::METRIC{42} = undef;
    Temporalio::Runtime::MetricMeter->_flush_pending;
    T2->is(scalar @{ $meter->records }, 1,
        'a disabled (undef) bind drops its buffered records');

    Temporalio::Runtime::MetricMeter->_clear_active;
});

# --- R60: the record_* threw warn is rate-limited ------------------------------

T2->subtest('R60 throwing record_* warns rate-limited, not per record' => sub {
    my $meter = ThrowingRecordMeter->new;
    Temporalio::Runtime::MetricMeter->_set_active($meter);
    $Temporalio::Runtime::MetricMeter::METRIC{7} = { name => 'thrower' };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    for my $i (1 .. 50) {
        Temporalio::Runtime::MetricMeter->_apply_record({
            metric_id     => 7,
            attributes_id => 0,
            record_kind   => 1,
            value         => $i,
            count         => 1,
        });
    }
    T2->is($meter->attempts, 50, 'every record was still attempted');
    T2->is(scalar @warnings, 1,
        '50 throwing records inside the rate window warn once, not 50 times');
    T2->like($warnings[0], qr/record_\* threw/, 'the one warn names the site');

    Temporalio::Runtime::MetricMeter->_clear_active;
});

# --- R60: the meter-method threw warn (dispatch site) is rate-limited ----------

T2->subtest('R60 throwing create_metric warns rate-limited across a drain' => sub {
    my $meter = ThrowingCreateMeter->new;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    with_meter_runtime($meter, sub ($rt) {
        my $metric_new = shim_fn(
            Temporalio::Core::FFI::meter_metric_new_ptr(),
            [ 'TemporalCoreByteArrayRef', 'TemporalCoreByteArrayRef',
              'TemporalCoreByteArrayRef', 'sint32' ],
            'opaque');
        $metric_new->(baref("m$_"), baref(''), baref(''), 1) for 1 .. 10;
        $rt->callback->drain($rt);    # ten throwing create_metric calls
    });
    my @threw = grep { /threw/ } @warnings;
    T2->is(scalar @threw, 1,
        '10 throwing creates inside the rate window warn once, not 10 times');
});

T2->done_testing;
