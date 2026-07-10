# ABOUTME: An autoscaling poller behavior (spec §29.3): core scales concurrent
# ABOUTME: poll calls between minimum and maximum (starting at initial) from
# ABOUTME: server backlog feedback. Packs as the TemporalCorePollerBehavior
# ABOUTME: autoscaling pointer (simple_maximum NULL).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();

# An autoscaling poller behavior. Defaults mirror sdk-python
# PollerBehaviorAutoscaling (_worker.py:63-82) and sdk-ruby Autoscaling
# (poller_behavior.rb:32-58): minimum=1, maximum=100, initial=5. Core opens
# between minimum and maximum concurrent poll calls, starting at initial,
# scaling with backlog. Constraint: minimum <= initial <= maximum, all positive.
class Temporalio::Worker::PollerBehavior::Autoscaling {
    field $minimum :param = 1;
    field $maximum :param = 100;
    field $initial :param = 5;

    ADJUST {
        for my $pair ([minimum => $minimum], [maximum => $maximum],
                      [initial => $initial]) {
            my ($name, $value) = @$pair;
            Temporalio::Exception::Argument->throw(
                message => "Autoscaling $name must be a positive integer")
                unless defined $value
                    && $value =~ /\A[0-9]+\z/
                    && $value >= 1;
        }
        Temporalio::Exception::Argument->throw(
            message => 'Autoscaling requires minimum <= initial <= maximum'
                . " (got minimum=$minimum initial=$initial maximum=$maximum)")
            unless $minimum <= $initial && $initial <= $maximum;
    }

    method minimum { $minimum }
    method maximum { $maximum }
    method initial { $initial }

    # _pack_spec -> the hash Temporalio::Core::FFI::WorkerOptions::pack_poller_behavior
    # consumes: { autoscaling => { minimum, maximum, initial } }.
    method _pack_spec {
        return { autoscaling => {
            minimum => $minimum,
            maximum => $maximum,
            initial => $initial,
        } };
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::PollerBehavior::Autoscaling - autoscaling poller behavior

=head1 SYNOPSIS

    my $behavior = Temporalio::Worker::PollerBehavior::Autoscaling->new(
        minimum => 1, maximum => 100, initial => 5);

=head1 DESCRIPTION

Lets core automatically scale the number of concurrent poll calls between
C<minimum> and C<maximum> (starting at C<initial>) based on server backlog
feedback (spec §29.3). A slot must be available before a poll begins. This is
entirely a core behavior toggled by the packed struct; there is no lang-side
scaling logic.

Defaults match the mature SDKs: C<minimum> 1, C<maximum> 100, C<initial> 5.
Construction enforces C<minimum> E<lt>= C<initial> E<lt>= C<maximum> with all
three positive.

=head1 METHODS

=head2 minimum

The minimum number of concurrent poll calls (assuming slots are available).

=head2 maximum

The maximum number of concurrent poll calls that will ever be open at once.

=head2 initial

The number of polls attempted initially before scaling kicks in.

=cut
