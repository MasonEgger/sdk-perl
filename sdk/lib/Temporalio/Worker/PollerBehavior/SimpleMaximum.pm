# ABOUTME: A simple-maximum poller behavior (spec §29.3): poll as long as a slot
# ABOUTME: is available, up to `maximum` concurrent poll requests. Packs as the
# ABOUTME: TemporalCorePollerBehavior simple_maximum pointer (autoscaling NULL).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();

# A simple-maximum poller behavior. `maximum` is the cap on concurrent poll
# requests (default 5; sdk-python _worker.py:49-60, sdk-ruby
# poller_behavior.rb:14-28). Core requires >= 2 for the workflow-task pool and
# >= 1 for the others; the universal floor (>= 1) is enforced here, the
# workflow-specific >= 2 is enforced where the workflow poller is resolved
# (Worker.pm) since the behavior object itself does not know its pool.
class Temporalio::Worker::PollerBehavior::SimpleMaximum {
    field $maximum :param = 5;

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => 'SimpleMaximum maximum must be a positive integer')
            unless defined $maximum
                && $maximum =~ /\A[0-9]+\z/
                && $maximum >= 1;
    }

    method maximum { $maximum }

    # _pack_spec -> the hash Temporalio::Core::FFI::WorkerOptions::pack_poller_behavior
    # consumes: { simple_maximum => $maximum }.
    method _pack_spec { return { simple_maximum => $maximum } }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::PollerBehavior::SimpleMaximum - simple-maximum poller behavior

=head1 SYNOPSIS

    my $behavior = Temporalio::Worker::PollerBehavior::SimpleMaximum->new(maximum => 5);

=head1 DESCRIPTION

Polls as long as a slot is available, up to C<maximum> concurrent poll requests
(spec §29.3). This is the default poller behavior (C<maximum> defaults to 5) and
the v0.1-parity behavior synthesized from the legacy C<max_concurrent_*_task_polls>
worker kwargs.

Core requires C<maximum> E<gt>= 2 for the workflow-task pool and E<gt>= 1 for the
other pools. The universal floor (E<gt>= 1) is validated at construction; the
workflow-task-specific E<gt>= 2 is enforced by L<Temporalio::Worker> when the
workflow poller is resolved.

=head1 METHODS

=head2 maximum

The maximum number of concurrent poll requests.

=cut
