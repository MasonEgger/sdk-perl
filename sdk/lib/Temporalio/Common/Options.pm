# ABOUTME: The one option-strictness contract shared across SDK surfaces (spec
# ABOUTME: R35 / finding A2, aligned with R44 client strictness and R55 typed
# ABOUTME: missing-arg errors): unknown option keys and missing required
# ABOUTME: activity timeouts raise Temporalio::Exception::Argument, typed.
package Temporalio::Common::Options;

use v5.38;
use warnings;

use Temporalio::Exception::Argument ();

# assert_known_keys($what, $opts, $known): reject unknown option keys, the ONE
# strictness rule (spec R35 finding A2; spec R44 finding A10 applies it across
# the whole client surface): a typo must raise, never vanish silently. $known
# is a { key => 1 } set; on the first unknown key (sorted, for a deterministic
# message) this throws a Temporalio::Exception::Argument naming the key and
# the known set. An empty $known set means the method takes no options at all.
sub assert_known_keys ($what, $opts, $known) {
    my $known_list = join(', ', sort keys %$known);
    for my $key (sort keys %$opts) {
        next if $known->{$key};
        Temporalio::Exception::Argument->throw(
            message => "$what: unknown option '$key' "
                     . ($known_list
                        ? "(known options: $known_list)"
                        : '(no options are accepted)'));
    }
    return;
}

# assert_activity_timeouts($what, $opts): require at least one of
# start_to_close_timeout / schedule_to_close_timeout (spec R35; Python parity:
# _workflow_instance.py _outbound_schedule_activity raises "Activity must have
# start_to_close_timeout or schedule_to_close_timeout"). Without one, the
# activity retries forever and the call hangs; fail typed at the call site
# instead.
sub assert_activity_timeouts ($what, $opts) {
    return if defined $opts->{start_to_close_timeout}
           || defined $opts->{schedule_to_close_timeout};
    Temporalio::Exception::Argument->throw(
        message => "$what: activity must have start_to_close_timeout or "
                 . 'schedule_to_close_timeout');
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Common::Options - the shared option-strictness contract

=head1 DESCRIPTION

One place for the rule that a mistyped or unsupported option key raises a
typed L<Temporalio::Exception::Argument> instead of vanishing silently, and
that a workflow-side activity call carries at least one of the two required
timeouts (spec R35, finding A2). The workflow activity call sites
(C<schedule_activity> / C<schedule_local_activity>) and the client surface
(spec R44, finding A10: L<Temporalio::Client> and every handle class it
returns) share this contract so the SDK has a single strictness story.

=head1 FUNCTIONS

=head2 assert_known_keys

C<< Temporalio::Common::Options::assert_known_keys($what, \%opts, \%known) >>
throws a L<Temporalio::Exception::Argument> naming the offending key and the
known-key set when C<%opts> contains a key absent from the C<%known> set
(a C<< { key => 1 } >> hashref). Returns nothing on success.

=head2 assert_activity_timeouts

C<< Temporalio::Common::Options::assert_activity_timeouts($what, \%opts) >>
throws a L<Temporalio::Exception::Argument> unless at least one of
C<start_to_close_timeout> / C<schedule_to_close_timeout> is defined in
C<%opts> (Python parity for the required-timeout rule).

=cut
