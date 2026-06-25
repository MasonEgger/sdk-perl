# ABOUTME: Duck-typed/subclassable custom metric meter (spec section 28.2):
# ABOUTME: core's eight meter callbacks land here via the shim, Ruby-shaped.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();

# The metric kinds, 1:1 with TemporalCoreMetricKind (header :23-31). Exposed so
# create_metric implementations and tests can name a kind without the magic
# number. CounterInteger, the histogram trio, the gauge pair, and the
# up/down counter.
package Temporalio::Runtime::MetricMeter::Kind {
    use constant {
        COUNTER_INTEGER         => 1,
        HISTOGRAM_INTEGER       => 2,
        HISTOGRAM_FLOAT         => 3,
        HISTOGRAM_DURATION      => 4,
        GAUGE_INTEGER           => 5,
        GAUGE_FLOAT             => 6,
        UP_DOWN_COUNTER_INTEGER => 7,
    };
}

class Temporalio::Runtime::MetricMeter {
    # The marshalled-request tags the shim parks for the main-thread drain,
    # mirroring TEMPORALIO_PERL_BRIDGE_METER_REQ_* in the shim.
    use constant {
        _REQ_METRIC_NEW      => 1,
        _REQ_ATTRIBUTES_NEW  => 2,
        _REQ_METRIC_FREE     => 3,
        _REQ_ATTRIBUTES_FREE => 4,
        _REQ_METER_FREE      => 5,
    };

    # The process-global active meter (spec section 28.2): the shim routes every
    # meter callback to a single registry, so the drain looks up the one active
    # meter here. Runtime->new sets it (and registers the shim queue);
    # Runtime->shutdown clears it. undef means no runtime carries a custom meter.
    our $ACTIVE;

    # Handle tables: SHIM-allocated ids -> the Perl objects create_metric /
    # new_attributes returned. The shim allocates the id (returned to core
    # synchronously) and parks a create request carrying it; this drain binds
    # the id here. The record drain looks metrics up by the same id. A bind that
    # has not landed yet (create request not drained) leaves the id absent, so
    # its buffered records are held until the bind (never dropped). A create
    # that returns undef binds the id to a disabled sentinel so its records
    # drop. Process-global alongside $ACTIVE (one meter at a time).
    our %METRIC;       # shim id => create_metric return value (undef = disabled)
    our %ATTRIBUTES;   # shim id => new_attributes return value

    sub active        ($class) { $ACTIVE }
    sub _set_active   ($class, $meter) {
        $ACTIVE     = $meter;
        %METRIC     = ();
        %ATTRIBUTES = ();
        return;
    }
    sub _clear_active ($class) {
        $ACTIVE     = undef;
        %METRIC     = ();
        %ATTRIBUTES = ();
        return;
    }

    # --- duck-typed surface (subclasses override) --------------------------
    #
    # A custom meter implements create_metric($name,$desc,$unit,$kind) returning
    # an opaque metric handle; record_integer/record_float/record_duration(
    # $metric,$value,$attrs); and new_attributes($append_from,\%attrs) returning
    # an opaque attribute-set handle. The base raises so a meter that forgets a
    # method fails loudly rather than silently dropping metrics. $attrs in
    # record_* is the attribute-set handle a prior new_attributes returned (or
    # undef for the default set).

    method create_metric ($name, $description, $unit, $kind) {
        Temporalio::Exception::Argument->throw(
            message => ref($self) . ' must implement create_metric'
                     . '($name, $description, $unit, $kind)',
        );
    }

    method record_integer ($metric, $value, $attributes) {
        Temporalio::Exception::Argument->throw(
            message => ref($self) . ' must implement record_integer'
                     . '($metric, $value, $attributes)',
        );
    }

    method record_float ($metric, $value, $attributes) {
        Temporalio::Exception::Argument->throw(
            message => ref($self) . ' must implement record_float'
                     . '($metric, $value, $attributes)',
        );
    }

    method record_duration ($metric, $value_ms, $attributes) {
        Temporalio::Exception::Argument->throw(
            message => ref($self) . ' must implement record_duration'
                     . '($metric, $value_ms, $attributes)',
        );
    }

    method new_attributes ($append_from, $attributes) {
        Temporalio::Exception::Argument->throw(
            message => ref($self) . ' must implement new_attributes'
                     . '($append_from, \%attributes)',
        );
    }

    # --- drain-side dispatch (called by Temporalio::Core::Callback) --------

    # Run one parked request the shim handed to the drain (via Callback). $tag
    # selects the operation; $request_ptr is the opaque pointer to the shim's
    # MeterRequest, read via the FFI req_* accessors. The shim already allocated
    # the handle id (returned to core synchronously); this binds it. A throwing
    # meter method must NEVER unwind across the C ABI boundary the drain runs
    # inside: it is caught, the handle bound to a disabled sentinel (undef) so
    # its records drop, and a rate-limited warn emitted.
    sub _run_request ($class, $tag, $request_ptr) {
        my $meter = $ACTIVE;
        return unless defined $meter;

        my $ok = eval { $class->_dispatch_request($meter, $tag, $request_ptr); 1 };
        unless ($ok) {
            warn "Temporalio::Runtime::MetricMeter: meter method threw,"
               . " disabling that handle: $@";
            # Bind the create id (if any) to disabled so its records drop.
            if ($tag == _REQ_METRIC_NEW || $tag == _REQ_ATTRIBUTES_NEW) {
                my $id = Temporalio::Core::FFI::meter_req_new_id($request_ptr);
                ($tag == _REQ_METRIC_NEW ? $METRIC{$id} : $ATTRIBUTES{$id}) = undef;
            }
        }
        return;
    }

    sub _dispatch_request ($class, $meter, $tag, $request_ptr) {
        if ($tag == _REQ_METRIC_NEW) {
            my $id   = Temporalio::Core::FFI::meter_req_new_id($request_ptr);
            my $name = Temporalio::Core::FFI::byte_array_ref_to_scalar(
                Temporalio::Core::FFI::meter_req_name($request_ptr));
            my $desc = Temporalio::Core::FFI::byte_array_ref_to_scalar(
                Temporalio::Core::FFI::meter_req_description($request_ptr));
            my $unit = Temporalio::Core::FFI::byte_array_ref_to_scalar(
                Temporalio::Core::FFI::meter_req_unit($request_ptr));
            my $kind = Temporalio::Core::FFI::meter_req_kind($request_ptr);
            # undef binds a disabled sentinel (records drop); a value binds the
            # handle so its records apply.
            $METRIC{$id} = $meter->create_metric($name, $desc, $unit, $kind);
            return;
        }
        if ($tag == _REQ_ATTRIBUTES_NEW) {
            my $id = Temporalio::Core::FFI::meter_req_new_id($request_ptr);
            my $append_from_id =
                Temporalio::Core::FFI::meter_req_append_from_id($request_ptr);
            my $append_from = $append_from_id
                ? $ATTRIBUTES{$append_from_id} : undef;
            my %attrs = $class->_decode_attributes($request_ptr);
            $ATTRIBUTES{$id} = $meter->new_attributes($append_from, \%attrs);
            return;
        }
        if ($tag == _REQ_METRIC_FREE) {
            my $free_id = Temporalio::Core::FFI::meter_req_free_id($request_ptr);
            delete $METRIC{$free_id};    # double-free no-ops (delete of absent)
            return;
        }
        if ($tag == _REQ_ATTRIBUTES_FREE) {
            my $free_id = Temporalio::Core::FFI::meter_req_free_id($request_ptr);
            delete $ATTRIBUTES{$free_id};
            return;
        }
        # _REQ_METER_FREE: the meter itself is being dropped; clear the tables.
        %METRIC     = ();
        %ATTRIBUTES = ();
        return;
    }

    # Decode the marshalled attribute set into a (key => value) hash. value_type
    # 1=String, 2=Int, 3=Float, 4=Bool (TemporalCoreMetricAttributeValueType).
    sub _decode_attributes ($class, $request_ptr) {
        my $count = Temporalio::Core::FFI::meter_req_attr_count($request_ptr);
        my %attrs;
        for my $i (0 .. $count - 1) {
            my $key = Temporalio::Core::FFI::byte_array_ref_to_scalar(
                Temporalio::Core::FFI::meter_req_attr_key($request_ptr, $i));
            my $type =
                Temporalio::Core::FFI::meter_req_attr_value_type($request_ptr, $i);
            $attrs{$key} =
                  $type == 1 ? Temporalio::Core::FFI::byte_array_ref_to_scalar(
                        Temporalio::Core::FFI::meter_req_attr_string($request_ptr, $i))
                : $type == 2 ? Temporalio::Core::FFI::meter_req_attr_int($request_ptr, $i)
                : $type == 3 ? Temporalio::Core::FFI::meter_req_attr_float($request_ptr, $i)
                : $type == 4 ? (Temporalio::Core::FFI::meter_req_attr_bool($request_ptr, $i) ? 1 : 0)
                :              undef;
        }
        return %attrs;
    }

    # Apply one drained aggregation bucket to the meter. $record is a hashref
    # { metric_id, attributes_id, record_kind (1=int,2=float,3=duration), value,
    # count }. Looks the metric and attribute handles up in the tables and calls
    # the matching record_* method. A stale/disabled handle (no table entry) is
    # dropped. A throwing record_* is caught (rate-limited warn) so it never
    # poisons sibling buckets in the drain batch.
    sub _apply_record ($class, $record) {
        my $meter = $ACTIVE;
        return unless defined $meter;

        # A bound handle (defined) applies; a disabled (undef sentinel), freed,
        # or not-yet-bound id drops. The Callback drain runs parked create
        # requests before records in the same cycle, so a metric recorded in the
        # same cycle it was created is already bound.
        my $metric = $METRIC{ $record->{metric_id} };
        return unless defined $metric;
        my $attributes = $record->{attributes_id}
            ? $ATTRIBUTES{ $record->{attributes_id} } : undef;

        my $kind  = $record->{record_kind};
        my $value = $record->{value};
        my $ok = eval {
            $kind == 1 ? $meter->record_integer($metric, $value, $attributes)
          : $kind == 2 ? $meter->record_float($metric, $value, $attributes)
          : $kind == 3 ? $meter->record_duration($metric, $value, $attributes)
          :              undef;
            1;
        };
        unless ($ok) {
            warn "Temporalio::Runtime::MetricMeter: record_* threw, dropping"
               . " aggregated value: $@";
        }
        return;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Runtime::MetricMeter - duck-typed custom metric meter for the core runtime

=head1 SYNOPSIS

    package My::Meter;
    use parent -norequire, 'Temporalio::Runtime::MetricMeter';
    sub create_metric ($self, $name, $desc, $unit, $kind) { ... }
    sub record_integer ($self, $metric, $value, $attrs) { ... }
    sub record_float ($self, $metric, $value, $attrs) { ... }
    sub record_duration ($self, $metric, $value_ms, $attrs) { ... }
    sub new_attributes ($self, $append_from, $attrs) { ... }

    use Temporalio::Runtime::TelemetryConfig;
    my $telemetry = Temporalio::Runtime::TelemetryConfig->new(
        metrics => My::Meter->new,
    );

=head1 DESCRIPTION

A custom metric meter (spec section 28.2): sdk-core calls it back for every
metric create and record through the C bridge's C<custom_meter> arm, the
third (and mutually exclusive) alternative to the OpenTelemetry and Prometheus
exporters. The interface is modelled on Ruby's C<Metric::Meter> (the Python
C<MetricBuffer> pull model is not implementable: the pinned C header has no
C<buffered_with_size>, only C<custom_meter>).

A meter is B<duck-typed>/subclassable. It implements:

=over 4

=item C<< create_metric($name, $description, $unit, $kind) >>

Returns an opaque metric handle (any Perl value), or C<undef> to disable the
metric (its records are then dropped). C<$kind> is a
L<Temporalio::Runtime::MetricMeter::Kind> constant.

=item C<< record_integer($metric, $value, $attributes) >>, C<< record_float >>, C<< record_duration >>

Record a value against a metric handle, with an optional attribute-set handle
(a C<new_attributes> return, or C<undef> for the default set).

=item C<< new_attributes($append_from, \%attributes) >>

Returns an opaque attribute-set handle. C<$append_from> is a prior handle to
extend (or C<undef>); C<\%attributes> is a key/value hash (string, integer,
float, or boolean values).

=back

=head2 Threading (spec section 28.2)

Core invokes the eight meter callbacks on B<arbitrary threads with
synchronous returns>. The Rust shim resolves the conflict with the SDK's
main-thread-only rule: C<record_*> calls B<aggregate in the shim> (pure Rust,
zero Perl contact) and the meter's C<record_*> methods run on the main-thread
drain pulling those aggregated buckets; C<create_metric>/C<new_attributes> and
the frees are B<main-thread-marshalled> (the shim parks a request and blocks
the core thread until the drain runs the Perl method). When a marshalled
callback fires on the main thread itself (e.g. metric creation during worker
construction) the shim runs the Perl method B<inline> to avoid self-deadlock.

A meter method that throws is caught and the affected handle disabled or the
record dropped (rate-limited C<warn>); a method must never unwind across the C
ABI.

=head1 CONSTRUCTOR

=head2 new

Constructs a meter. Subclasses typically add their own fields and override the
duck-typed methods above.

=head1 METHODS

=head2 active

Class method returning the process-global active meter (the one
L<Temporalio::Runtime> installed), or C<undef> when no runtime carries a custom
meter.

=head2 create_metric / record_integer / record_float / record_duration / new_attributes

The duck-typed surface described above. The base implementations raise
L<Temporalio::Exception::Argument> so a meter that omits a method fails loudly.

=cut
