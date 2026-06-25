# ABOUTME: Runtime logging configuration (spec section 4.2): wraps either a
# ABOUTME: LoggingFilter or a raw filter string; optionally forwards core logs.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use FFI::Platypus::Buffer ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();
use Temporalio::Runtime::LoggingFilter ();
use Temporalio::Runtime::LogForwardingConfig ();

class Temporalio::Runtime::LoggingConfig {
    # Either a Temporalio::Runtime::LoggingFilter or a raw filter string.
    field $filter :param = Temporalio::Runtime::LoggingFilter->new;

    # Optional log forwarding (spec section 28.1): a
    # Temporalio::Runtime::LogForwardingConfig, or undef for no forwarding (the
    # default — forward_to stays NULL in the FFI record). The name is kept as
    # forward_to for bridge symmetry (resolved decision, spec section 28.1).
    field $forward_to :param = undef;

    ADJUST {
        if (ref $filter
            && !(Scalar::Util::blessed($filter)
                 && $filter->isa('Temporalio::Runtime::LoggingFilter'))) {
            Temporalio::Exception::Argument->throw(
                message => 'filter must be a Temporalio::Runtime::LoggingFilter'
                         . ' or a raw filter string',
            );
        }
        if (defined $forward_to
            && !(Scalar::Util::blessed($forward_to)
                 && $forward_to->isa('Temporalio::Runtime::LogForwardingConfig'))) {
            Temporalio::Exception::Argument->throw(
                message => 'forward_to must be a'
                         . ' Temporalio::Runtime::LogForwardingConfig or undef',
            );
        }
    }

    # Default logging configuration: core WARN, other ERROR (the
    # LoggingFilter defaults, matching the reference SDKs).
    sub default ($class) { return $class->new }

    method filter     { $filter }
    method forward_to { $forward_to }

    method filter_string () {
        return ref $filter ? $filter->to_string : $filter;
    }

    # Builds a TemporalCoreLoggingOptions record. Anything backing record
    # pointers (here the filter string scalar) is pushed onto @$keep, which
    # the caller must hold for as long as the record may be dereferenced. When
    # forwarding is configured the forward_to slot carries the shim's kind-7
    # trampoline pointer; routing is process-global (Runtime->new registers
    # the queue and the active LogForwardingConfig), so no per-call user_data.
    method to_ffi ($keep) {
        my $filter_string = $self->filter_string;
        push @$keep, \$filter_string;
        my ($data, $size) = FFI::Platypus::Buffer::scalar_to_buffer($filter_string);
        return Temporalio::Core::FFI::LoggingOptions->new(
            filter_data => $data,
            filter_size => $size,
            forward_to  => defined $forward_to
                ? Temporalio::Core::FFI::forwarded_log_callback_ptr()
                : undef,
        );
    }
}

1;

__END__

=head1 NAME

Temporalio::Runtime::LoggingConfig - logging configuration for the core runtime

=head1 SYNOPSIS

    use Temporalio::Runtime::LoggingConfig;
    use Temporalio::Runtime::LoggingFilter;

    my $config = Temporalio::Runtime::LoggingConfig->new(
        filter => Temporalio::Runtime::LoggingFilter->new(
            core_level  => 'INFO',
            other_level => 'WARN',
        ),
    );
    # or a raw tracing filter string:
    $config = Temporalio::Runtime::LoggingConfig->new(filter => 'temporal_sdk_core=DEBUG');

    my $default = Temporalio::Runtime::LoggingConfig->default;

=head1 DESCRIPTION

Carries the log filter for the core runtime (spec section 4.2). C<filter>
accepts a L<Temporalio::Runtime::LoggingFilter> or a raw string; any other
reference raises L<Temporalio::Exception::Argument>. C<forward_to> optionally
takes a L<Temporalio::Runtime::LogForwardingConfig> to surface core's
structured logs through a Perl logger (spec section 28.1); C<undef> (the
default) means no forwarding. C<to_ffi(\@keep)> produces the
C<TemporalCoreLoggingOptions> record: C<forward_to> is NULL without
forwarding, else the shim's kind-7 trampoline pointer (routing is
process-global, set up by L<Temporalio::Runtime>). Buffers backing the
record are pushed onto C<@keep> and must outlive any use of the record.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Runtime::LoggingConfig->new(
        filter => ...,
    );

Constructs a Temporalio::Runtime::LoggingConfig. Named parameters:

=over 4

=item C<filter>

(optional, default C<Temporalio::Runtime::LoggingFilter->new>)

=item C<forward_to>

(optional, default C<undef>) A L<Temporalio::Runtime::LogForwardingConfig>
enabling core-log forwarding, or C<undef> for none.

=back

=head1 METHODS

=head2 default

Class method returning the default logging config.

=head2 filter

Accessor returning the C<filter> value.

=head2 forward_to

Accessor returning the C<forward_to> value (a
L<Temporalio::Runtime::LogForwardingConfig> or C<undef>).

=head2 filter_string

Returns the resolved core/other-level filter string passed to sdk-core.

=head2 to_ffi

Returns the FFI logging-options record for this config.

=cut
