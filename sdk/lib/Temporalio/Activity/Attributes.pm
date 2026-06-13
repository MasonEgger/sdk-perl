# ABOUTME: Parses the :Defn attribute payload for class-based activities (spec section 9.1).
# ABOUTME: Resolves the activity type name and the no_thread_cancellation option.
package Temporalio::Activity::Attributes;

use v5.38;
use warnings;

# Parse the $data arrayref handed to the :Defn handler (spec section 10.1
# constraint 4: $data is an ARRAYREF or undef, never a bare string).
#
#   :Defn                                     -> undef          (default name)
#   :Defn('Custom')                           -> ['Custom']     (explicit name)
#   :Defn(name=Custom,no_thread_cancellation=1) -> ['name=Custom', 'no_thread_cancellation=1']
#
# Returns ($name, %opts). $name defaults to the method name, or the class
# basename when the decorated method is named "run".
sub parse_defn ($data, $method_name, $pkg) {
    my $default_name = $method_name eq 'run' ? _basename($pkg) : $method_name;

    return ($default_name) if !defined $data;

    my @items = ref($data) eq 'ARRAY' ? @$data : ($data);

    # First decide whether this is the kwargs form. The kwargs form is any
    # token containing '='; otherwise the single positional token is the name.
    my $name;
    my %opts;
    my $saw_kwarg = 0;

    for my $item (@items) {
        if (defined $item && $item =~ /\A\s*([^=\s]+)\s*=\s*(.*?)\s*\z/) {
            $saw_kwarg = 1;
            my ($k, $v) = ($1, $2);
            if ($k eq 'name') {
                $name = $v;
            }
            elsif ($k eq 'no_thread_cancellation') {
                $opts{no_thread_cancellation} = $v ? 1 : 0;
            }
            elsif ($k eq 'sync') {
                $opts{sync} = $v ? 1 : 0;
            }
            else {
                require Temporalio::Exception::Argument;
                Temporalio::Exception::Argument->throw(
                    message => "Unknown :Defn option '$k'",
                );
            }
        }
        elsif (!$saw_kwarg && !defined $name) {
            # Positional name (the :Defn('Custom') form).
            $name = $item;
        }
    }

    $name //= $default_name;
    return ($name, %opts);
}

sub _basename ($pkg) {
    my @parts = split /::/, $pkg;
    return $parts[-1];
}

1;

__END__

=head1 NAME

Temporalio::Activity::Attributes - parse the :Defn attribute payload

=head1 DESCRIPTION

Helper used by L<Temporalio::Activity::Definition>'s C<:Defn> handler to turn
the C<Attribute::Handlers> C<$data> payload into an activity type name plus
options. Supports the bare, positional-name, and keyword forms documented in
spec section 9.1.

=cut
