# ABOUTME: A complete schedule (spec section 25): action/spec/policy/state,
# ABOUTME: mapped to temporal.api.schedule.v1.Schedule (policy<->policies).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Schedule::Action ();
use Temporalio::Schedule::Spec ();
use Temporalio::Schedule::Policy ();
use Temporalio::Schedule::State ();

class Temporalio::Schedule::Schedule {
    field $action :param;
    field $spec   :param = undef;
    field $policy :param = undef;    # -> proto field `policies`
    field $state  :param = undef;

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => 'schedule requires an action')
            unless defined $action;
        $spec   //= Temporalio::Schedule::Spec->new;
        $policy //= Temporalio::Schedule::Policy->new;
        $state  //= Temporalio::Schedule::State->new;
    }

    method action { $action }
    method spec   { $spec }
    method policy { $policy }
    method state  { $state }

    # _to_proto($client) — async; the action encodes payloads. Note the proto
    # field is `policies` (plural) but the Perl param is `policy`.
    async method _to_proto ($client) {
        my $Schedule = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.Schedule');
        return $Schedule->new({
            spec     => $spec->_to_proto,
            action   => await $action->_to_proto($client),
            policies => $policy->_to_proto,
            state    => $state->_to_proto,
        });
    }

    sub _from_proto ($class, $sched) {
        # The generated proto reader for the `state` field is `state_` (a bare
        # `state` collides with a base-class method), but `new` still accepts
        # the plain `state` key.
        return $class->new(
            action => Temporalio::Schedule::Action->_from_proto($sched->action),
            spec   => Temporalio::Schedule::Spec->_from_proto($sched->spec),
            policy => Temporalio::Schedule::Policy->_from_proto($sched->policies),
            state  => Temporalio::Schedule::State->_from_proto($sched->state_),
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::Schedule - a complete schedule definition

=head1 SYNOPSIS

    my $schedule = Temporalio::Schedule::Schedule->new(
        action => $action,
        spec   => $spec,
        policy => $policy,
        state  => $state,
    );

=head1 DESCRIPTION

A complete schedule (spec section 25), mapped to
C<temporal.api.schedule.v1.Schedule>. The Perl C<policy> field maps to the
proto C<policies> field (plural). C<_to_proto($client)> is async because the
action encodes payloads through the client's data converter.

=head1 CONSTRUCTOR

=head2 new

    my $s = Temporalio::Schedule::Schedule->new(action => $a, %optional);

Named parameters: C<action> (required), C<spec>, C<policy>, C<state> (each
defaulting to an empty instance of the corresponding class).

=head1 METHODS

=head2 action

Accessor returning the schedule action.

=head2 spec

Accessor returning the schedule spec.

=head2 policy

Accessor returning the schedule policy.

=head2 state

Accessor returning the schedule state.

=cut
