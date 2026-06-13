# ABOUTME: Workflow/activity task priority (spec section 7.4), mapping to the
# ABOUTME: temporal.api.common.v1.Priority proto message.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();

class Temporalio::Common::Priority {
    # priority_key: lower number = higher priority. undef leaves it unset
    # (proto default 0 = "use the queue default").
    field $priority_key :param = undef;

    method priority_key { $priority_key }

    method to_proto {
        my $Priority = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.Priority');
        my %args;
        $args{priority_key} = $priority_key if defined $priority_key;
        return $Priority->new(\%args);
    }
}

1;

__END__

=head1 NAME

Temporalio::Common::Priority - workflow/activity task priority

=head1 SYNOPSIS

    use Temporalio::Common::Priority;

    my $priority = Temporalio::Common::Priority->new(priority_key => 1);
    my $proto    = $priority->to_proto;  # temporal.api.common.v1.Priority

=head1 DESCRIPTION

Task priority passed to C<start_workflow> (spec section 7.4). A lower
C<priority_key> means higher priority; an undef key leaves the proto field
unset so the server uses the task-queue default. C<to_proto> builds the
C<temporal.api.common.v1.Priority> message.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Common::Priority->new(
        priority_key => ...,
    );

Constructs a Temporalio::Common::Priority. Named parameters:

=over 4

=item C<priority_key>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 priority_key

Accessor returning the C<priority_key> value.

=head2 to_proto

Builds and returns the C<temporal.api.common.v1.Priority> proto message for this priority.

=cut
