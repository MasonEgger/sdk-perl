# ABOUTME: Parses the :Defn attribute payload for class-based activities (spec section 9.1).
# ABOUTME: Resolves the activity type name and the no_thread_cancellation option.
package Temporalio::Activity::Attributes;

use v5.38;
use warnings;

# Parse the $data arrayref handed to the :Defn handler (spec section 10.1
# constraint 4: $data is an ARRAYREF or undef, never a bare string).
#
#   :Defn                          -> undef               (default name)
#   :Defn('Custom')                -> ['Custom']          (explicit name)
#   :Defn('Custom', 'sync=1')      -> ['Custom', 'sync=1'] (kwargs form)
#
# The kwargs tokens MUST be quoted. Attribute::Handlers eval()s the paren
# content as a Perl list; an unquoted token like name=Custom is not a valid
# expression, so the whole thing collapses to one string ("name=Custom,sync=1")
# and the name silently absorbs the trailing options. parse_defn rejects that
# below rather than registering a broken type name.
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

    # Catch the unquoted kwargs mistake: :Defn(name=Foo,sync=1) collapses to the
    # single string "name=Foo,sync=1", so the name above captures "Foo,sync=1".
    # A real activity type name never contains ',' or '='; reject it with the
    # fix rather than registering an activity the workflow can never resolve.
    if ($name =~ /[,=]/) {
        require Temporalio::Exception::Argument;
        Temporalio::Exception::Argument->throw(
            message =>
                "Invalid :Defn activity name '$name': a type name cannot "
              . "contain ',' or '='. Quote each kwargs token so Perl passes "
              . "them separately, e.g. :Defn('Foo', 'sync=1') "
              . "(not :Defn(name=Foo,sync=1)).",
        );
    }

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

=head1 METHODS

=head2 parse_defn

Attribute-handler entry point for the C<:Defn> activity-method attribute; registers the method as an activity definition. Internal mechanism (spec section 10.1).

=cut
