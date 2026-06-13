# ABOUTME: HTTP/2 keep-alive configuration for client connections (spec
# ABOUTME: section 7.2): interval/timeout seconds + the record builder.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::FFI ();

class Temporalio::Client::KeepAliveConfig {
    # Defaults verified against sdk-python service.py KeepAliveConfig
    # (interval_millis 30000 / timeout_millis 15000). Seconds Perl-side.
    field $interval :param = 30;
    field $timeout  :param = 15;

    method interval { $interval }
    method timeout  { $timeout }

    # Builds the TemporalCoreClientKeepAliveOptions record (no backing
    # buffers; @$keep is accepted for builder-signature uniformity).
    method to_ffi ($keep = undef) {
        return Temporalio::Core::FFI::ClientKeepAliveOptions->new(
            interval_millis => int($interval * 1000),
            timeout_millis  => int($timeout * 1000),
        );
    }
}

1;

__END__

=head1 NAME

Temporalio::Client::KeepAliveConfig - HTTP/2 keep-alive for client connections

=head1 SYNOPSIS

    use Temporalio::Client::KeepAliveConfig;

    my $keep_alive = Temporalio::Client::KeepAliveConfig->new(
        interval => 30,    # seconds (defaults shown)
        timeout  => 15,
    );

=head1 DESCRIPTION

HTTP/2 keep-alive ping configuration for L<Temporalio::Client> connections
(spec section 7.2): a ping every C<interval> seconds that must be answered
within C<timeout> seconds or the connection is closed. Defaults match the
reference SDKs (30/15). C<to_ffi> builds the
C<TemporalCoreClientKeepAliveOptions> record in milliseconds.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Client::KeepAliveConfig->new(
        interval => ...,
        timeout => ...,
    );

Constructs a Temporalio::Client::KeepAliveConfig. Named parameters:

=over 4

=item C<interval>

(optional, default C<30>)

=item C<timeout>

(optional, default C<15>)

=back

=head1 METHODS

=head2 interval

Accessor returning the C<interval> value.

=head2 timeout

Accessor returning the C<timeout> value.

=head2 to_ffi

Returns the FFI representation of this keep-alive config consumed by the connect call.

=cut
