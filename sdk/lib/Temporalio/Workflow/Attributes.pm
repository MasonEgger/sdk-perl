# ABOUTME: Parses the :Signal/:Query/:Update/:Run attribute payloads for workflows (spec section 10.1).
# ABOUTME: Resolves the handler name (default = method name; explicit override) and the dynamic flag.
package Temporalio::Workflow::Attributes;

use v5.38;
use warnings;

# Parse the $data arrayref handed to a workflow attribute handler (spec
# section 10.1 constraint 4: $data is an ARRAYREF or undef, never a bare
# string). Used for :Signal / :Query / :Update.
#
#   :Signal                 -> undef             (default name = method name)
#   :Signal('foo')          -> ['foo']           (explicit name)
#   :Signal(name=foo)       -> ['name=foo']      (kwargs name)
#   :Signal(dynamic=1)      -> ['dynamic=1']     (dynamic handler — no name)
#
# Returns ($name, %opts). For a dynamic handler the name is undef (mirrors
# sdk-python's `name is None` dynamic contract and sdk-ruby's "Cannot provide
# name if dynamic is true"). Otherwise $name defaults to $method_name.
sub parse_handler ($data, $method_name, $kind) {
    return ($method_name) if !defined $data;

    my @items = ref($data) eq 'ARRAY' ? @$data : ($data);

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
            elsif ($k eq 'dynamic') {
                $opts{dynamic} = $v ? 1 : 0;
            }
            else {
                require Temporalio::Exception::Argument;
                Temporalio::Exception::Argument->throw(
                    message => "Unknown :$kind option '$k'",
                );
            }
        }
        elsif (!$saw_kwarg && !defined $name) {
            # Positional name (the :Signal('foo') form).
            $name = $item;
        }
    }

    if ($opts{dynamic}) {
        # A dynamic handler must not carry an explicit name (sdk-ruby:
        # "Cannot provide name if dynamic is true"; sdk-python: dynamic =
        # name is None).
        if (defined $name) {
            require Temporalio::Exception::Argument;
            Temporalio::Exception::Argument->throw(
                message => "Cannot provide a name for a dynamic :$kind handler",
            );
        }
        return (undef, %opts);
    }

    $name //= $method_name;

    # Catch the unquoted kwargs mistake: :Signal(name=foo,dynamic=1) collapses
    # to the single string "name=foo,dynamic=1", so the name above captures
    # "foo,dynamic=1". A real handler name never contains ',' or '='; reject it
    # with the fix rather than registering a handler that can never be matched.
    if ($name =~ /[,=]/) {
        require Temporalio::Exception::Argument;
        Temporalio::Exception::Argument->throw(
            message =>
                "Invalid :$kind name '$name': a handler name cannot contain "
              . "',' or '='. Quote each kwargs token so Perl passes them "
              . "separately, e.g. :$kind('foo', 'dynamic=1') "
              . "(not :$kind(name=foo,dynamic=1)).",
        );
    }

    return ($name, %opts);
}

# Parse the :Run / :Init payload. The workflow type for a :Run named "run"
# defaults to the class basename (spec section 8.6); any other :Run method
# defaults to the method name; an explicit :Run('Custom') overrides.
#
# Returns the resolved workflow type name.
sub parse_run ($data, $method_name, $pkg) {
    my $default = $method_name eq 'run' ? _basename($pkg) : $method_name;

    return $default if !defined $data;

    my @items = ref($data) eq 'ARRAY' ? @$data : ($data);

    my $name;
    my $saw_kwarg = 0;
    for my $item (@items) {
        if (defined $item && $item =~ /\A\s*([^=\s]+)\s*=\s*(.*?)\s*\z/) {
            $saw_kwarg = 1;
            my ($k, $v) = ($1, $2);
            if ($k eq 'name') {
                $name = $v;
            }
            else {
                require Temporalio::Exception::Argument;
                Temporalio::Exception::Argument->throw(
                    message => "Unknown :Run option '$k'",
                );
            }
        }
        elsif (!$saw_kwarg && !defined $name) {
            $name = $item;
        }
    }

    return $name // $default;
}

sub _basename ($pkg) {
    my @parts = split /::/, $pkg;
    return $parts[-1];
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::Attributes - parse workflow attribute payloads

=head1 DESCRIPTION

Helper used by L<Temporalio::Workflow::Definition>'s attribute handlers to
turn the C<Attribute::Handlers> C<$data> payload into a handler name plus
options (spec section 10.1). Supports the bare, positional-name, and keyword
(C<name=...>, C<dynamic=...>) forms for C<:Signal>/C<:Query>/C<:Update>, and
the workflow-type resolution for C<:Run> (basename for a method named C<run>,
the method name otherwise, or an explicit override).

=head1 METHODS

=head2 parse_handler

Attribute-handler entry point for the C<:Signal>/C<:Query>/C<:Update> workflow-method attributes. Internal mechanism (spec section 10.1).

=head2 parse_run

Attribute-handler entry point for the C<:Run> workflow-method attribute. Internal mechanism (spec section 10.1).

=cut
