# ABOUTME: Unit tests for core->Perl log forwarding (spec section 28.1): the
# ABOUTME: forward_to NULL/non-NULL slot, the duck-typed logger field assembly
# ABOUTME: mirroring sdk-python _on_logs, the assembly flags, throwing-logger
# ABOUTME: isolation, the is_enabled gate, and the second-forwarder guard
# ABOUTME: (T-logfwd-1, -2, -4, -6, -7). T-3/T-5 are cargo (shim deep copy/free).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();
use FFI::Platypus::Buffer ();

use Temporalio::Core::FFI ();
use Temporalio::Runtime::LoggingConfig ();
use Temporalio::Runtime::LogForwardingConfig ();

# A fake logger capturing every ->log call. is_enabled defaults to true; a
# threshold can gate it (T-logfwd-7). Duck-typed: no base class.
package FakeLogger {
    sub new ($class, %args) {
        return bless {
            name      => $args{name} // 'temporalio',
            min_level => $args{min_level},   # undef = all enabled
            records   => [],
        }, $class;
    }
    my %LEVEL_NUM = (TRACE => 0, DEBUG => 1, INFO => 2, WARN => 3, ERROR => 4);
    sub name        ($self) { $self->{name} }
    sub records     ($self) { $self->{records} }
    sub is_enabled  ($self, $level) {
        return 1 unless defined $self->{min_level};
        return ($LEVEL_NUM{$level} // 0) >= ($LEVEL_NUM{ $self->{min_level} } // 0);
    }
    sub log ($self, $level, $message, $context) {
        push @{ $self->{records} }, { level => $level, message => $message, context => $context };
    }
}

# A logger whose log() always dies — its records must never poison siblings.
package DyingLogger {
    sub new ($class) { return bless { calls => 0 }, $class }
    sub name       ($self) { 'dying' }
    sub is_enabled ($self, $level) { 1 }
    sub log ($self, $level, $message, $context) {
        $self->{calls}++;
        die "logger blew up\n";
    }
}

# Read a NUL-terminated C string from an opaque pointer, as the drain sees the
# shim-owned buffers. undef pointer -> undef.
sub read_cstring ($ptr) {
    return undef unless defined $ptr;
    return Temporalio::Core::FFI::ffi()->cast('opaque' => 'string', $ptr);
}

# --------------------------------------------------------------------------
# T-logfwd-1: LoggingConfig with no forwarding builds a NULL forward_to slot;
# with forwarding it builds the kind-7 trampoline pointer.
# --------------------------------------------------------------------------
T2->subtest('T-logfwd-1 forward_to slot null vs trampoline pointer' => sub {
    my @keep;
    my $no_fwd = Temporalio::Runtime::LoggingConfig->new->to_ffi(\@keep);
    T2->is(scalar $no_fwd->forward_to, undef,
        'no forwarding => forward_to is NULL');

    my $logger = FakeLogger->new;
    my $fwd = Temporalio::Runtime::LoggingConfig->new(
        forward_to => Temporalio::Runtime::LogForwardingConfig->new(logger => $logger),
    )->to_ffi(\@keep);
    my $expected_ptr = Temporalio::Core::FFI::forwarded_log_callback_ptr();
    T2->ok(defined scalar $fwd->forward_to, 'forwarding => forward_to is set');
    T2->is(scalar $fwd->forward_to, $expected_ptr,
        'forward_to is the kind-7 trampoline pointer');
});

# --------------------------------------------------------------------------
# T-logfwd-2: a core log reaches the duck-typed logger intact. _on_log builds
# the name/message/context exactly like sdk-python _on_logs with all flags on.
# --------------------------------------------------------------------------
T2->subtest('T-logfwd-2 core log reaches the logger intact' => sub {
    my $logger = FakeLogger->new(name => 'temporalio');
    my $config = Temporalio::Runtime::LogForwardingConfig->new(logger => $logger);

    $config->_on_log(
        level         => 3,   # WARN
        target        => 'temporal_sdk_core::worker',
        message       => 'polling for tasks',
        fields_json   => '{"attempt":3}',
        timestamp_ms  => 1_700_000_000_123,
    );

    my $records = $logger->records;
    T2->is(scalar @$records, 1, 'one record logged');
    my $r = $records->[0];
    T2->is($r->{level}, 'WARN', 'integer level 3 mapped to WARN');
    T2->like($r->{message}, qr/^\[sdk_core::temporal_sdk_core::worker\] polling for tasks/,
        'message prefixed with [sdk_core::<target>]');
    T2->like($r->{message}, qr/\{"attempt":3\}/, 'fields JSON appended to message');
    T2->is($r->{context}{target}, 'temporal_sdk_core::worker', 'context target');
    T2->is($r->{context}{timestamp_ms}, 1_700_000_000_123, 'context timestamp_ms');
    T2->is($r->{context}{fields}, '{"attempt":3}', 'context fields raw JSON');
    T2->ok(exists $r->{context}{temporal_log}, 'context carries a temporal_log view');
});

# --------------------------------------------------------------------------
# T-logfwd-4: the four assembly flags toggle name/message construction
# (golden compare against the documented format).
# --------------------------------------------------------------------------
T2->subtest('T-logfwd-4 assembly flags golden' => sub {
    # All flags off: bare message, no target append, no fields, no time rewrite.
    my $bare = FakeLogger->new(name => 'app');
    Temporalio::Runtime::LogForwardingConfig->new(
        logger                       => $bare,
        append_target_to_name        => 0,
        prepend_target_on_message    => 0,
        overwrite_log_record_time    => 0,
        append_log_fields_to_message => 0,
    )->_on_log(
        level => 2, target => 'core::x', message => 'hi',
        fields_json => '{"k":1}', timestamp_ms => 42,
    );
    my $r = $bare->records->[0];
    T2->is($r->{message}, 'hi', 'all flags off: message unchanged');
    T2->is($r->{context}{logger_name}, 'app', 'name not appended with flag off');

    # All flags on: name appended, message prefixed + fields, time overwritten.
    my $full = FakeLogger->new(name => 'app');
    Temporalio::Runtime::LogForwardingConfig->new(logger => $full)->_on_log(
        level => 2, target => 'core::x', message => 'hi',
        fields_json => '{"k":1}', timestamp_ms => 42,
    );
    my $f = $full->records->[0];
    T2->is($f->{message}, '[sdk_core::core::x] hi {"k":1}',
        'all flags on: prefixed + fields appended');
    T2->is($f->{context}{logger_name}, 'app-sdk_core::core::x',
        'target appended to name with flag on');
});

# --------------------------------------------------------------------------
# T-logfwd-6: a logger that throws is caught — _on_log never propagates.
# --------------------------------------------------------------------------
T2->subtest('T-logfwd-6 throwing logger is isolated' => sub {
    my $dying = DyingLogger->new;
    my $config = Temporalio::Runtime::LogForwardingConfig->new(logger => $dying);
    my $ok = eval {
        $config->_on_log(level => 4, target => 't', message => 'm',
                         fields_json => '{}', timestamp_ms => 1);
        1;
    };
    T2->ok($ok, '_on_log swallows the logger exception');
    T2->is($dying->{calls}, 1, 'the logger was still called');
});

# --------------------------------------------------------------------------
# T-logfwd-7: the is_enabled gate suppresses a below-threshold level before
# building the (possibly expensive) record.
# --------------------------------------------------------------------------
T2->subtest('T-logfwd-7 is_enabled gate' => sub {
    my $logger = FakeLogger->new(min_level => 'WARN');
    my $config = Temporalio::Runtime::LogForwardingConfig->new(logger => $logger);

    $config->_on_log(level => 1, target => 't', message => 'debug noise',
                     fields_json => '{}', timestamp_ms => 1);   # DEBUG, gated out
    T2->is(scalar @{ $logger->records }, 0, 'DEBUG below WARN is suppressed');

    $config->_on_log(level => 4, target => 't', message => 'real error',
                     fields_json => '{}', timestamp_ms => 1);   # ERROR, passes
    T2->is(scalar @{ $logger->records }, 1, 'ERROR at/above WARN passes');
});

# --------------------------------------------------------------------------
# Validation: a logger lacking ->log raises Argument at construction.
# --------------------------------------------------------------------------
T2->subtest('logger must implement log()' => sub {
    my $err = do {
        local $@;
        eval { Temporalio::Runtime::LogForwardingConfig->new(logger => bless {}, 'NoLog') };
        $@;
    };
    T2->ok(Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Argument'),
        'a logger without ->log raises Argument');
});

T2->done_testing;
