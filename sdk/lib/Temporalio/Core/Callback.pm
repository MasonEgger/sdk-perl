# ABOUTME: Wakeup-fd owner for the shim callback queue (spec section 4.5).
# ABOUTME: Constructor-only stub: the drain loop / Future resolution is P1.2.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Runtime ();

class Temporalio::Core::Callback {
    field $read_handle;     # what the IO::Async loop watches
    field $write_handle;    # pipe write end (undef when eventfd: one fd)
    field $signal_fd;       # fd number the shim queue writes to

    # Eventfd on Linux (Linux::FD::Event), nonblocking pipe elsewhere (or if
    # Linux::FD is unavailable). The choice is hidden here: the rest of the
    # SDK only sees an IO::Async-compatible read end plus the signal fd
    # number to hand to temporalio_perl_bridge_queue_new. The queue borrows
    # the fd and never closes it; this object owns both ends (spec section 3).
    ADJUST {
        if ($^O eq 'linux' && eval { require Linux::FD::Event; 1 }) {
            my $event_fd = Linux::FD::Event->new(0, 'non-blocking');
            $read_handle = $event_fd;
            $signal_fd   = fileno($event_fd);
        }
        else {
            pipe($read_handle, $write_handle)
                or Temporalio::Exception::Runtime->throw(
                    message => "could not create wakeup pipe: $!");
            $read_handle->blocking(0);
            $write_handle->blocking(0);
            $signal_fd = fileno($write_handle);
        }
    }

    method read_handle () { $read_handle }
    method signal_fd ()   { $signal_fd }

    # Close the Perl-owned fd(s). Call only after the shim queue is freed:
    # the queue borrows signal_fd and must never write to a closed fd.
    method close () {
        close $read_handle  if defined $read_handle;
        close $write_handle if defined $write_handle;
        ($read_handle, $write_handle, $signal_fd) = (undef, undef, undef);
        return;
    }
}

1;

__END__

=head1 NAME

Temporalio::Core::Callback - wakeup fd for the shim completion queue

=head1 SYNOPSIS

    use Temporalio::Core::Callback;

    my $callback  = Temporalio::Core::Callback->new;
    my $queue_ptr = Temporalio::Core::FFI::queue_new($callback->signal_fd);
    # ... register $callback->read_handle with an IO::Async::Loop ...
    Temporalio::Core::FFI::queue_free($queue_ptr);
    $callback->close;

=head1 DESCRIPTION

Owns the wakeup fd that the C<temporalio-perl-bridge> completion queue
signals from Tokio threads: an eventfd via L<Linux::FD::Event> on Linux
(nonblocking), or a nonblocking C<pipe(2)> pair elsewhere. C<signal_fd> is
the fd number passed to C<temporalio_perl_bridge_queue_new>; C<read_handle>
is the IO::Async-compatible read end. The queue borrows the fd and never
closes it - call C<close> after the queue is freed.

This is the Phase 0 constructor-only stub of the spec section 4.5
component; C<issue_async> and the drain loop land in P1.2.

=cut
