# ABOUTME: Forwards sdk-core's structured logs to a duck-typed Perl logger
# ABOUTME: (spec section 28.1): field assembly mirrors sdk-python _on_logs.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Exception::Argument ();

class Temporalio::Runtime::LogForwardingConfig {
    # The destination logger. Duck-typed (resolved decision, spec section
    # 28.1): it must implement log($level, $message, \%context); an optional
    # is_enabled($level) gates a level before the record is built. Thin
    # Log::Any / Log::Dispatch adapters can wrap a real logger.
    field $logger :param;

    # Field-assembly flags (defaults match sdk-python LogForwardingConfig):
    # all on. Each toggles one piece of the name/message construction.
    field $append_target_to_name        :param = 1;
    field $prepend_target_on_message    :param = 1;
    field $overwrite_log_record_time    :param = 1;
    field $append_log_fields_to_message :param = 1;

    # sdk-core ForwardedLogLevel (runtime.rs): Trace=0..Error=4. The forwarded
    # level arrives as this integer in the kind-7 entry's rpc_status_code slot.
    my @LEVEL_NAME = qw(TRACE DEBUG INFO WARN ERROR);

    ADJUST {
        unless (Scalar::Util::blessed($logger) && $logger->can('log')) {
            Temporalio::Exception::Argument->throw(
                message => 'logger must be an object implementing'
                         . ' log($level, $message, \%context)',
            );
        }
    }

    # The process-global active forwarding config (spec section 28.1): the
    # shim routes every forwarded log to a single registry, so the Perl drain
    # looks up the one active LogForwardingConfig here. Runtime->new sets it
    # (and registers the shim queue); Runtime->shutdown clears it. undef means
    # no runtime is forwarding — a stray kind-7 entry is then dropped.
    our $ACTIVE;

    sub active        ($class) { $ACTIVE }
    sub _set_active   ($class, $config) { $ACTIVE = $config; return }
    sub _clear_active ($class) { $ACTIVE = undef; return }

    method logger                       { $logger }
    method append_target_to_name        { $append_target_to_name }
    method prepend_target_on_message    { $prepend_target_on_message }
    method overwrite_log_record_time    { $overwrite_log_record_time }
    method append_log_fields_to_message { $append_log_fields_to_message }

    # Map a numeric ForwardedLogLevel to its name; out-of-range falls back to
    # ERROR (loud rather than silent — an unknown level is still surfaced).
    sub _level_name ($level) {
        return $LEVEL_NAME[$level] // 'ERROR';
    }

    # Drain-side entry point (spec section 28.1): called by the Callback drain
    # for each kind-7 entry. Builds the record exactly like sdk-python
    # _on_logs and hands it to the logger. Named args:
    #   level => 0..4, target => $str, message => $str,
    #   fields_json => $str, timestamp_ms => $int
    # A throwing logger is caught and dropped (rate-limited warn) so it can
    # never poison sibling completions sharing the drain batch.
    method _on_log (%args) {
        my $level_name = _level_name($args{level} // 4);

        # Level gate before building the record (mirrors logger.isEnabledFor).
        return if $logger->can('is_enabled') && !$logger->is_enabled($level_name);

        my $target      = $args{target}       // '';
        my $message     = $args{message}      // '';
        my $fields_json = $args{fields_json}  // '';
        my $timestamp   = $args{timestamp_ms} // 0;

        my $name = $logger->can('name') ? $logger->name : undef;
        $name = (defined $name ? $name : '') . "-sdk_core::$target"
            if $append_target_to_name;

        $message = "[sdk_core::$target] $message" if $prepend_target_on_message;
        $message .= " $fields_json"
            if $append_log_fields_to_message && length $fields_json;

        my %context = (
            target      => $target,
            timestamp_ms => $timestamp,
            fields      => $fields_json,
            logger_name => $name,
            # A view of the raw core log, mirroring sdk-python's temporal_log
            # record attribute: enough to reconstruct the original.
            temporal_log => {
                level        => $level_name,
                target       => $target,
                message      => $args{message} // '',
                fields       => $fields_json,
                timestamp_ms => $timestamp,
            },
        );
        $context{overwrite_time} = $timestamp if $overwrite_log_record_time;

        my $ok = eval { $logger->log($level_name, $message, \%context); 1 };
        unless ($ok) {
            warn "Temporalio::Runtime::LogForwardingConfig: forwarded-log"
               . " logger threw, dropping record: $@";
        }
        return;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Runtime::LogForwardingConfig - forward sdk-core logs to a Perl logger

=head1 SYNOPSIS

    use Temporalio::Runtime::LogForwardingConfig;
    use Temporalio::Runtime::LoggingConfig;

    my $config = Temporalio::Runtime::LogForwardingConfig->new(
        logger => $my_logger,                  # ->log($level, $msg, \%ctx)
        append_target_to_name        => 1,
        prepend_target_on_message    => 1,
        overwrite_log_record_time    => 1,
        append_log_fields_to_message => 1,
    );

    my $logging = Temporalio::Runtime::LoggingConfig->new(forward_to => $config);

=head1 DESCRIPTION

Surfaces sdk-core's structured logs through a Perl logger (spec section
28.1). The logger is B<duck-typed>: it must implement C<< log($level,
$message, \%context) >>, and may implement C<< is_enabled($level) >> (a
level gate applied before the record is built) and C<< name() >> (used when
C<append_target_to_name> is set). C<$level> is one of C<TRACE>, C<DEBUG>,
C<INFO>, C<WARN>, C<ERROR>; C<%context> carries C<target>, C<timestamp_ms>,
C<fields> (the raw fields JSON), C<logger_name>, and C<temporal_log> (a hash
view of the original core log).

Field assembly mirrors sdk-python C<_on_logs> exactly: the four flags
(default on) control whether the target is appended to the logger name, the
message is prefixed with C<[sdk_core::E<lt>targetE<gt>]>, the record time is
overwritten with the core log time, and the fields JSON is appended to the
message.

A logger that throws is caught and dropped (rate-limited C<warn>) so it can
never poison sibling completions sharing the drain batch.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Runtime::LogForwardingConfig->new(
        logger => ...,
        append_target_to_name => ...,
        prepend_target_on_message => ...,
        overwrite_log_record_time => ...,
        append_log_fields_to_message => ...,
    );

Constructs a Temporalio::Runtime::LogForwardingConfig. Named parameters:

=over 4

=item C<logger>

(required) An object implementing C<< log($level, $message, \%context) >>.
A value that is not such an object raises L<Temporalio::Exception::Argument>.

=item C<append_target_to_name>

(optional, default C<1>)

=item C<prepend_target_on_message>

(optional, default C<1>)

=item C<overwrite_log_record_time>

(optional, default C<1>)

=item C<append_log_fields_to_message>

(optional, default C<1>)

=back

=head1 METHODS

=head2 active

    my $config = Temporalio::Runtime::LogForwardingConfig->active;

Class method returning the process-global active forwarding config (the one
L<Temporalio::Runtime> installed), or C<undef> when no runtime is forwarding
core logs. The kind-7 drain dispatches forwarded logs to it.

=head2 logger

Accessor returning the destination logger.

=head2 append_target_to_name / prepend_target_on_message / overwrite_log_record_time / append_log_fields_to_message

Accessors returning the corresponding assembly flag.

=cut
