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

# ---------------------------------------------------------------------------
# The user-facing EMISSION surface (spec R83; parity in-workflow finding 6,
# schedule/runtime finding 2, nexus finding 4): the meter user code records
# metrics TO, mirroring sdk-python's common.MetricMeter over runtime.py:595's
# core-backed _MetricMeter. Distinct from the custom-sink CONSUMER class below
# (spec section 28.2), which receives what core emits. One meter/instrument
# wrapper is shared by all three contexts: workflow (replay-suppressed via the
# suppress gate), activity, and Nexus.
#
# These classes are defined BEFORE the consumer class: its signatured named
# subs would otherwise poison the next `field :param` parse (the perl 5.38.2
# parser-state bug in lessons.md).
# ---------------------------------------------------------------------------

# A meter: creates instruments against a backend and carries a base
# attribute-set handle plus the replay-suppression gate. Backends are
# duck-typed (CoreBackend, NoopBackend, or a test double) with the contract:
#   create_instrument($kind, $name, $description, $unit) -> opaque handle
#   attributes($base_or_undef, \%attrs)                  -> opaque handle
#   record($instrument_handle, $value, $attrs_or_undef)  -> void
#   release_attributes($handle)   (optional; frees a per-call ephemeral set)
class Temporalio::Runtime::MetricMeter::Meter {
    field $backend  :param;
    field $attrs    :param = undef;   # backend attribute-set handle
    field $suppress :param = undef;   # coderef; true return drops emits

    # The shared process noop meter (sdk-python common.MetricMeter.noop):
    # what Runtime->metric_meter returns when core has no metrics exporter.
    our $NOOP;
    sub noop {
        return $NOOP //= Temporalio::Runtime::MetricMeter::Meter->new(
            backend => Temporalio::Runtime::MetricMeter::NoopBackend->new);
    }

    # create_counter/create_histogram/create_gauge($name, description => ...,
    # unit => ...) -> a Temporalio::Runtime::MetricMeter::Instrument. The
    # integer kinds, matching Python's create_counter/create_histogram/
    # create_gauge (common.py:755-853).
    method create_counter ($name, %options) {
        return $self->_create_instrument(
            Temporalio::Runtime::MetricMeter::Kind::COUNTER_INTEGER,
            counter => $name, %options);
    }

    method create_histogram ($name, %options) {
        return $self->_create_instrument(
            Temporalio::Runtime::MetricMeter::Kind::HISTOGRAM_INTEGER,
            histogram => $name, %options);
    }

    method create_gauge ($name, %options) {
        return $self->_create_instrument(
            Temporalio::Runtime::MetricMeter::Kind::GAUGE_INTEGER,
            gauge => $name, %options);
    }

    method _create_instrument ($kind, $style, $name, %options) {
        my $description = delete $options{description};
        my $unit        = delete $options{unit};
        if (my @unknown = sort keys %options) {
            Temporalio::Exception::Argument->throw(
                message => "create_$style: unknown option(s): @unknown");
        }
        if (!defined $name || !length $name) {
            Temporalio::Exception::Argument->throw(
                message => "create_$style requires a metric name");
        }
        return Temporalio::Runtime::MetricMeter::Instrument->new(
            backend     => $backend,
            handle      => $backend->create_instrument(
                $kind, $name, $description, $unit),
            style       => $style,
            name        => $name,
            description => $description,
            unit        => $unit,
            attrs       => $attrs,
            suppress    => $suppress,
        );
    }

    # with_additional_attributes(\%attrs) -> a new meter whose instruments
    # carry the current set plus \%attrs (Python common.py:854-869).
    method with_additional_attributes ($additional) {
        return Temporalio::Runtime::MetricMeter::Meter->new(
            backend  => $backend,
            attrs    => $backend->attributes($attrs, $additional),
            suppress => $suppress,
        );
    }

    # _with_suppress($coderef) -> a new meter whose instruments drop emits
    # while $coderef returns true. SDK-internal: the workflow Runner installs
    # its replay gate here (the Perl form of Python's _ReplaySafeMetricMeter,
    # _workflow_instance.py:3571).
    method _with_suppress ($code) {
        return Temporalio::Runtime::MetricMeter::Meter->new(
            backend  => $backend,
            attrs    => $attrs,
            suppress => $code,
        );
    }
}

# Parser-state firewall (the perl 5.38.2 bug in lessons.md): a signatured
# named sub compiled in an EARLIER file (e.g. Temporalio::Nexus's helpers)
# can make the next `field :param` in THIS file die "Subroutine attributes
# must come before the signature"; a file-scope signature-less named sub
# resets the state (verified empirically for this file's class boundaries).
sub Temporalio::Runtime::MetricMeter::_parser_state_reset_1 { }

# One instrument (counter, histogram, or gauge). The emit method is gated by
# style — add for counters, record for histograms, set for gauges — each
# taking ($value, \%per_call_attributes). Shared by the workflow, activity,
# and Nexus context meters (the spec R83 one-wrapper requirement).
class Temporalio::Runtime::MetricMeter::Instrument {
    field $backend     :param;
    field $handle      :param;    # backend instrument handle (undef = noop)
    field $style       :param;    # 'counter' | 'histogram' | 'gauge'
    field $name        :param;
    field $description :param = undef;
    field $unit        :param = undef;
    field $attrs       :param = undef;
    field $suppress    :param = undef;

    method name        { return $name }
    method description { return $description }
    method unit        { return $unit }

    # add($value, \%attrs) — counters only (Python MetricCounter.add).
    method add ($value, $additional = undef) {
        $self->_assert_style(counter => 'add');
        return $self->_emit($value, $additional);
    }

    # record($value, \%attrs) — histograms only (Python MetricHistogram.record).
    method record ($value, $additional = undef) {
        $self->_assert_style(histogram => 'record');
        return $self->_emit($value, $additional);
    }

    # set($value, \%attrs) — gauges only (Python MetricGauge.set).
    method set ($value, $additional = undef) {
        $self->_assert_style(gauge => 'set');
        return $self->_emit($value, $additional);
    }

    # with_additional_attributes(\%attrs) -> a new instrument over the same
    # backend handle with the appended set (Python common.py:895-911).
    method with_additional_attributes ($additional) {
        return Temporalio::Runtime::MetricMeter::Instrument->new(
            backend     => $backend,
            handle      => $handle,
            style       => $style,
            name        => $name,
            description => $description,
            unit        => $unit,
            attrs       => $backend->attributes($attrs, $additional),
            suppress    => $suppress,
        );
    }

    method _assert_style ($expected, $operation) {
        return if $style eq $expected;
        Temporalio::Exception::Argument->throw(
            message => "$operation is only valid on a $expected instrument"
                     . " ('$name' is a $style)");
    }

    method _emit ($value, $additional) {
        if (!defined $value
            || !Scalar::Util::looks_like_number($value)
            || $value < 0) {
            # Python parity: every instrument raises on a negative value
            # (runtime.py _MetricCounter.add and siblings).
            Temporalio::Exception::Argument->throw(
                message => "metric value must be a non-negative number"
                         . " (metric '$name')");
        }
        # The replay gate: suppression skips ALL emission work, including the
        # per-call attribute build (Python's replay-safe instruments skip the
        # underlying call entirely, _workflow_instance.py:3652-3663).
        return if defined $suppress && $suppress->();

        my $set = $attrs;
        my $ephemeral;
        if (defined $additional && %$additional) {
            $ephemeral = $backend->attributes($set, $additional);
            $set = $ephemeral;
        }
        $backend->record($handle, $value, $set);
        # A per-call set is ephemeral: release it now so a hot loop cannot
        # accumulate core attribute handles (long-lived sets are freed by the
        # backend at close). Optional in the backend contract.
        $backend->release_attributes($ephemeral)
            if defined $ephemeral && $backend->can('release_attributes');
        return;
    }
}

# Parser-state firewall; see _parser_state_reset_1 above.
sub Temporalio::Runtime::MetricMeter::_parser_state_reset_2 { }

# The FFI backend over the CORE meter surface (spec R83): temporal_core_
# metric_meter_new / metric_new / metric_attributes_new[_append] /
# metric_record_integer, the same C functions sdk-python's bridge metric
# module wraps. Owned by Temporalio::Runtime, which closes it at shutdown
# (before runtime_free) so no metric call can outlive the core runtime.
class Temporalio::Runtime::MetricMeter::CoreBackend {
    field $meter_ptr :param;    # TemporalCoreMetricMeter*

    field $closed = 0;
    field $default_attrs;       # lazily-created empty base set
    field %owned_attrs;         # attrs ptr => 1; freed at close
    field @owned_metrics;       # metric ptrs; freed at close

    method create_instrument ($kind, $name, $description, $unit) {
        return undef if $closed;
        my @keep;
        my ($name_data, $name_size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $name);
        my ($desc_data, $desc_size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $description);
        my ($unit_data, $unit_size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $unit);
        my $options = Temporalio::Core::FFI::MetricOptions->new(
            name_data        => $name_data,
            name_size        => $name_size,
            description_data => $desc_data,
            description_size => $desc_size,
            unit_data        => $unit_data,
            unit_size        => $unit_size,
            kind             => $kind,
        );
        my $metric_ptr =
            Temporalio::Core::FFI::metric_new($meter_ptr, $options);
        push @owned_metrics, $metric_ptr if defined $metric_ptr;
        return $metric_ptr;
    }

    method attributes ($base, $attrs) {
        return $base if $closed;
        return $base unless defined $attrs && %$attrs;
        my @keep;
        my ($array_ptr, $count) =
            Temporalio::Core::FFI::keep_metric_attribute_array(\@keep, $attrs);
        my $attrs_ptr = defined $base
            ? Temporalio::Core::FFI::metric_attributes_new_append(
                $meter_ptr, $base, $array_ptr, $count)
            : Temporalio::Core::FFI::metric_attributes_new(
                $meter_ptr, $array_ptr, $count);
        $owned_attrs{$attrs_ptr} = 1 if defined $attrs_ptr;
        return $attrs_ptr;
    }

    method record ($handle, $value, $attrs) {
        return if $closed || !defined $handle;
        # The bridge DEREFERENCES the attributes pointer unconditionally
        # (metric.rs temporal_core_metric_record_integer), so a record with
        # no attribute set must pass the empty default set, never NULL.
        Temporalio::Core::FFI::metric_record_integer(
            $handle, int($value), $attrs // $self->_default_attrs);
        return;
    }

    # Free an ephemeral per-call attribute set immediately (the Instrument
    # emit path); a set this backend does not own is left alone.
    method release_attributes ($attrs_ptr) {
        return unless defined $attrs_ptr && delete $owned_attrs{$attrs_ptr};
        Temporalio::Core::FFI::metric_attributes_free($attrs_ptr);
        return;
    }

    # The empty base attribute set (core's default attributes plus nothing).
    # The array pointer must be non-NULL even for a zero count (the bridge
    # slices it), so a kept dummy buffer rides along for the call.
    method _default_attrs () {
        return $default_attrs //= do {
            my @keep;
            my ($dummy_ptr) =
                Temporalio::Core::FFI::keep_buffer(\@keep, "\0" x 8);
            my $attrs_ptr = Temporalio::Core::FFI::metric_attributes_new(
                $meter_ptr, $dummy_ptr, 0);
            $owned_attrs{$attrs_ptr} = 1 if defined $attrs_ptr;
            $attrs_ptr;
        };
    }

    # Tear the backend down (Temporalio::Runtime::shutdown, BEFORE the core
    # runtime is freed): free every owned attribute set and metric, then the
    # meter. Instruments and meters holding this backend become safe no-ops.
    method close () {
        return if $closed;
        $closed = 1;
        Temporalio::Core::FFI::metric_attributes_free($_)
            for keys %owned_attrs;
        %owned_attrs   = ();
        $default_attrs = undef;
        Temporalio::Core::FFI::metric_free($_) for splice @owned_metrics;
        Temporalio::Core::FFI::metric_meter_free($meter_ptr)
            if defined $meter_ptr;
        $meter_ptr = undef;
        return;
    }
}

# Parser-state firewall; see _parser_state_reset_1 above.
sub Temporalio::Runtime::MetricMeter::_parser_state_reset_3 { }

# The do-nothing backend behind the shared noop meter (Python's
# _NoopMetricMeter): instruments are created and emits drop silently.
class Temporalio::Runtime::MetricMeter::NoopBackend {
    method create_instrument ($kind, $name, $description, $unit) {
        return undef;
    }
    method attributes ($base, $attrs) { return undef }
    method record ($handle, $value, $attrs) { return }
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
    # the id here. The record drain looks metrics up by the same id. A bind
    # that has not landed yet (create request not drained) leaves the id
    # absent, so its records buffer in %PENDING until the bind lands (never
    # dropped; finding L28 / spec R60, the same promise the shim registry doc
    # makes). A create that returns undef binds the id to a disabled
    # sentinel so its records drop. Process-global alongside $ACTIVE (one
    # meter at a time).
    our %METRIC;       # shim id => create_metric return value (undef = disabled)
    our %ATTRIBUTES;   # shim id => new_attributes return value

    # Records drained before their metric's create request bound (the shim
    # parks requests and aggregates records on separate channels, so a core
    # thread can slip a create in after the drain's requests loop but record
    # before the records snapshot). Bounded to one drain cycle: FIFO request
    # order means a pending id's create is ALWAYS in the very next requests
    # loop, and _flush_pending (run right after that loop) applies the buffer.
    # (Finding L28 / spec R60: buffer-until-bound, never dropped.)
    our %PENDING;      # shim metric id => [record hashrefs awaiting the bind]

    # Frees drained this cycle, applied only AFTER the records drain
    # (_apply_deferred_frees). FIFO parking means a create+record+free burst
    # between two wakeups would otherwise bind and immediately delete the
    # handle in the requests loop, and the records drain would then drop the
    # value (finding L28 / spec R60). Any record for a freed id was aggregated
    # before the free was parked, so it is always visible to the records drain
    # of the same cycle that defers the free: deleting afterwards loses
    # nothing, and no stale record can still reference the deleted id.
    our @DEFERRED_FREE;    # [ 'metric' | 'attributes', shim id ] pairs

    # Rate-limit state for the two warn sites (the POD promises rate-limited
    # warns; finding L28 / spec R60 flagged them as unconditional). At most one
    # warn per site per $WARN_INTERVAL_SECONDS window.
    our %WARN_LAST;    # site key => epoch seconds of the last emitted warn
    our $WARN_INTERVAL_SECONDS = 5;

    sub active        ($class) { $ACTIVE }
    sub _set_active   ($class, $meter) {
        $ACTIVE        = $meter;
        %METRIC        = ();
        %ATTRIBUTES    = ();
        %PENDING       = ();
        @DEFERRED_FREE = ();
        %WARN_LAST     = ();
        return;
    }
    sub _clear_active ($class) {
        $ACTIVE        = undef;
        %METRIC        = ();
        %ATTRIBUTES    = ();
        %PENDING       = ();
        @DEFERRED_FREE = ();
        %WARN_LAST     = ();
        return;
    }

    # Emit $message via warn at most once per $WARN_INTERVAL_SECONDS per site
    # key, as the POD promises (finding L28 / spec R60). A throwing meter in a
    # hot record path would otherwise warn once per aggregated bucket.
    sub _warn_rate_limited ($class, $site, $message) {
        my $now  = time;
        my $last = $WARN_LAST{$site};
        return if defined $last && ($now - $last) < $WARN_INTERVAL_SECONDS;
        $WARN_LAST{$site} = $now;
        warn $message;
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
            $class->_warn_rate_limited(dispatch_threw =>
                "Temporalio::Runtime::MetricMeter: meter method threw,"
              . " disabling that handle: $@");
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
        # Frees are DEFERRED to _apply_deferred_frees (after the records drain
        # of the same cycle) so a create+record+free burst parked between two
        # wakeups cannot delete the handle before its records apply (finding
        # L28 / spec R60). Double-free stays a no-op (delete of absent).
        if ($tag == _REQ_METRIC_FREE) {
            my $free_id = Temporalio::Core::FFI::meter_req_free_id($request_ptr);
            push @DEFERRED_FREE, [ metric => $free_id ];
            return;
        }
        if ($tag == _REQ_ATTRIBUTES_FREE) {
            my $free_id = Temporalio::Core::FFI::meter_req_free_id($request_ptr);
            push @DEFERRED_FREE, [ attributes => $free_id ];
            return;
        }
        # _REQ_METER_FREE: the meter itself is being dropped; clear the tables
        # (buffered records and deferred frees included; nothing can bind or
        # apply after this).
        %METRIC        = ();
        %ATTRIBUTES    = ();
        %PENDING       = ();
        @DEFERRED_FREE = ();
        return;
    }

    # Apply records that buffered in %PENDING before their metric's create
    # request bound (finding L28 / spec R60: buffer-until-bound). Called by the
    # drain right after the requests loop: FIFO parking guarantees any pending
    # id's create was in that loop, so an id still unbound here belongs to a
    # create parked mid-cycle and stays buffered for the next cycle. A bind to
    # the disabled sentinel (undef) makes _apply_record drop the buffer.
    sub _flush_pending ($class) {
        for my $id (keys %PENDING) {
            next unless exists $METRIC{$id};
            my $records = delete $PENDING{$id};
            $class->_apply_record($_) for @$records;
        }
        return;
    }

    # Run the frees deferred during this cycle's requests loop (finding L28 /
    # spec R60). Called by the drain after the records drain: every record for
    # a freed id was aggregated before the free was parked and the records
    # drain loops until empty, so all of them applied already; deleting now
    # loses nothing and no stale record can reference the id later (shim ids
    # are monotonic, never reused).
    sub _apply_deferred_frees ($class) {
        for my $free (splice @DEFERRED_FREE) {
            my ($which, $id) = @$free;
            if ($which eq 'metric') {
                delete $METRIC{$id};
                delete $PENDING{$id};    # belt-and-braces; flushed already
            }
            else {
                delete $ATTRIBUTES{$id};
            }
        }
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
    # the matching record_* method. A not-yet-bound id buffers in %PENDING
    # until its create request lands (finding L28 / spec R60: never dropped);
    # a disabled handle (undef sentinel) drops. A throwing record_* is caught
    # (rate-limited warn) so it never poisons sibling buckets in the drain
    # batch.
    sub _apply_record ($class, $record) {
        my $meter = $ACTIVE;
        return unless defined $meter;

        # An id with no table entry at all is a create parked after this
        # cycle's requests loop (frees defer past this drain, and shim ids are
        # never reused, so absent means not-yet-bound): buffer until the bind
        # lands. A disabled bind (undef sentinel) drops.
        if (!exists $METRIC{ $record->{metric_id} }) {
            push @{ $PENDING{ $record->{metric_id} } }, $record;
            return;
        }
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
            $class->_warn_rate_limited(record_threw =>
                "Temporalio::Runtime::MetricMeter: record_* threw, dropping"
              . " aggregated value: $@");
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

Records are never dropped by the marshalling (finding L28 / spec R60,
buffer-until-bound): a record drained before its metric's create request has
bound is buffered and applied once the bind lands, and frees apply only after
the record drain, so a create/record/free burst between two drain wakeups
loses nothing. The only records intentionally dropped are those of a disabled
metric (C<create_metric> returned C<undef> or threw) and any still buffered
when the runtime shuts down.

A meter method that throws is caught and the affected handle disabled or the
record dropped (a C<warn> rate-limited to one per site per five seconds); a
method must never unwind across the C ABI.

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

=head1 EMISSION SURFACE (spec R83)

This file also carries the user-facing B<emission> classes: the meter user
code records metrics TO, the mirror image of the custom-sink consumer above.
One meter/instrument wrapper is shared by the workflow, activity, and Nexus
contexts (parity: in-workflow finding 6, schedule/runtime finding 2, nexus
finding 4; Python C<common.MetricMeter> over C<runtime.py>'s core-backed
implementation).

=head2 Temporalio::Runtime::MetricMeter::Meter

    my $meter   = $runtime->metric_meter;             # or a context meter
    my $counter = $meter->create_counter('requests',
        description => 'inbound requests', unit => 'requests');
    $counter->add(1, { route => '/foo' });

Created by L<Temporalio::Runtime/metric_meter> over the core meter, or the
shared noop meter (class method C<noop>) when no metrics exporter is
configured. Methods:

=over 4

=item C<< create_counter($name, description => ..., unit => ...) >>

=item C<< create_histogram($name, description => ..., unit => ...) >>

=item C<< create_gauge($name, description => ..., unit => ...) >>

Each returns a L</Temporalio::Runtime::MetricMeter::Instrument> of the
matching integer kind. An unknown option or missing name raises
L<Temporalio::Exception::Argument>.

=item C<< with_additional_attributes(\%attrs) >>

A new meter whose instruments carry the current attribute set plus
C<\%attrs>. Attribute values are strings, integers, floats, or booleans.

=item C<noop>

Class method returning the shared do-nothing meter.

=back

=head2 Temporalio::Runtime::MetricMeter::Instrument

One counter, histogram, or gauge. C<add($value, \%attrs)> (counters),
C<record($value, \%attrs)> (histograms), and C<set($value, \%attrs)> (gauges)
record a non-negative value with optional per-call attributes merged over the
instrument's set; a negative value or a wrong-style call raises
L<Temporalio::Exception::Argument>. C<name> / C<description> / C<unit> read
the creation arguments; C<with_additional_attributes(\%attrs)> derives a new
instrument over the same underlying metric.

B<Replay safety:> a workflow-context instrument silently drops emits while
the activation replays (the Runner installs the gate), matching Python's
C<_ReplaySafeMetricMeter>. Instruments are still created during replay.

The backends (C<::CoreBackend> over the C C<temporal_core_metric_*> surface,
freed at runtime shutdown, and C<::NoopBackend>) are internal.

=cut
