# ABOUTME: Runtime logging configuration (spec section 4.2): wraps either a
# ABOUTME: LoggingFilter or a raw filter string; builds the LoggingOptions record.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use FFI::Platypus::Buffer ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();
use Temporalio::Runtime::LoggingFilter ();

class Temporalio::Runtime::LoggingConfig {
    # Either a Temporalio::Runtime::LoggingFilter or a raw filter string.
    # Log forwarding to a Perl logger is deferred past v0.1 (spec section 15),
    # so forward_to is always NULL in the FFI record.
    field $filter :param = Temporalio::Runtime::LoggingFilter->new;

    ADJUST {
        if (ref $filter
            && !(Scalar::Util::blessed($filter)
                 && $filter->isa('Temporalio::Runtime::LoggingFilter'))) {
            Temporalio::Exception::Argument->throw(
                message => 'filter must be a Temporalio::Runtime::LoggingFilter'
                         . ' or a raw filter string',
            );
        }
    }

    # Default logging configuration: core WARN, other ERROR (the
    # LoggingFilter defaults, matching the reference SDKs).
    sub default ($class) { return $class->new }

    method filter { $filter }

    method filter_string () {
        return ref $filter ? $filter->to_string : $filter;
    }

    # Builds a TemporalCoreLoggingOptions record. Anything backing record
    # pointers (here the filter string scalar) is pushed onto @$keep, which
    # the caller must hold for as long as the record may be dereferenced.
    method to_ffi ($keep) {
        my $filter_string = $self->filter_string;
        push @$keep, \$filter_string;
        my ($data, $size) = FFI::Platypus::Buffer::scalar_to_buffer($filter_string);
        return Temporalio::Core::FFI::LoggingOptions->new(
            filter_data => $data,
            filter_size => $size,
            forward_to  => undef,
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
reference raises L<Temporalio::Exception::Argument>. C<to_ffi(\@keep)>
produces the C<TemporalCoreLoggingOptions> record with C<forward_to> NULL
(log forwarding is deferred past v0.1, spec section 15); buffers backing the
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

=back

=head1 METHODS

=head2 default

Class method returning the default logging config.

=head2 filter

Accessor returning the C<filter> value.

=head2 filter_string

Returns the resolved core/other-level filter string passed to sdk-core.

=head2 to_ffi

Returns the FFI logging-options record for this config.

=cut
