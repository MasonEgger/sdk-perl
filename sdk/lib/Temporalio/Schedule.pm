# ABOUTME: Umbrella for the Temporalio::Schedule::* data classes (spec section
# ABOUTME: 25): loads the flat tree and exposes short constructor helpers.
use v5.38;
use warnings;

package Temporalio::Schedule;

use Temporalio::Schedule::Schedule ();
use Temporalio::Schedule::Spec ();
use Temporalio::Schedule::Calendar ();
use Temporalio::Schedule::Range ();
use Temporalio::Schedule::Interval ();
use Temporalio::Schedule::State ();
use Temporalio::Schedule::Policy ();
use Temporalio::Schedule::Action ();
use Temporalio::Schedule::Backfill ();
use Temporalio::Schedule::Update ();
use Temporalio::Schedule::Description ();
use Temporalio::Schedule::Info ();
use Temporalio::Schedule::ListDescription ();

# Short constructor helpers mirroring the flat class tree (spec section 25).
sub schedule (%kw)  { Temporalio::Schedule::Schedule->new(%kw) }
sub spec (%kw)      { Temporalio::Schedule::Spec->new(%kw) }
sub calendar (%kw)  { Temporalio::Schedule::Calendar->new(%kw) }
sub range (@args)   { Temporalio::Schedule::Range->new(@args) }
sub interval (%kw)  { Temporalio::Schedule::Interval->new(%kw) }
sub state (%kw)     { Temporalio::Schedule::State->new(%kw) }
sub policy (%kw)    { Temporalio::Schedule::Policy->new(%kw) }
sub backfill (%kw)  { Temporalio::Schedule::Backfill->new(%kw) }
sub update (%kw)    { Temporalio::Schedule::Update->new(%kw) }

sub start_workflow (%kw) {
    Temporalio::Schedule::Action::StartWorkflow->new(%kw);
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule - data classes for Temporal schedules

=head1 SYNOPSIS

    use Temporalio::Schedule ();

    my $schedule = Temporalio::Schedule::Schedule->new(
        action => Temporalio::Schedule::Action::StartWorkflow->new(
            workflow => 'MyWorkflow', id => 'sched-wf', task_queue => 'tq'),
        spec   => Temporalio::Schedule::Spec->new(
            intervals => [ Temporalio::Schedule::Interval->new(every => 3600) ]),
    );

=head1 DESCRIPTION

The umbrella module for the flat C<Temporalio::Schedule::*> data-class tree
(spec section 25). Loading it pulls in every schedule data class:
L<Temporalio::Schedule::Schedule>, L<Temporalio::Schedule::Spec>,
L<Temporalio::Schedule::Calendar>, L<Temporalio::Schedule::Range>,
L<Temporalio::Schedule::Interval>, L<Temporalio::Schedule::State>,
L<Temporalio::Schedule::Policy>, L<Temporalio::Schedule::Action>,
L<Temporalio::Schedule::Backfill>, L<Temporalio::Schedule::Update>,
L<Temporalio::Schedule::Description>, L<Temporalio::Schedule::Info>, and
L<Temporalio::Schedule::ListDescription>.

It also exposes short package-function constructors (C<schedule>, C<spec>,
C<calendar>, C<range>, C<interval>, C<state>, C<policy>, C<backfill>,
C<update>, C<start_workflow>) for terse schedule construction.

=head1 FUNCTIONS

=head2 schedule

Constructs a L<Temporalio::Schedule::Schedule>.

=head2 spec

Constructs a L<Temporalio::Schedule::Spec>.

=head2 calendar

Constructs a L<Temporalio::Schedule::Calendar>.

=head2 range

Constructs a L<Temporalio::Schedule::Range>.

=head2 interval

Constructs a L<Temporalio::Schedule::Interval>.

=head2 state

Constructs a L<Temporalio::Schedule::State>.

=head2 policy

Constructs a L<Temporalio::Schedule::Policy>.

=head2 backfill

Constructs a L<Temporalio::Schedule::Backfill>.

=head2 update

Constructs a L<Temporalio::Schedule::Update>.

=head2 start_workflow

Constructs a L<Temporalio::Schedule::Action::StartWorkflow>.

=cut
