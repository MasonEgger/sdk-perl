# ABOUTME: Base class for all Temporalio exceptions (spec section 6.1).
# ABOUTME: Carries message/stack_trace/cause; stringifies the full cause chain.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Devel::StackTrace ();
use Scalar::Util ();

class Temporalio::Exception {
    use overload
        q{""}    => sub { $_[0]->as_string },
        fallback => 1;

    field $message :param;
    field $stack_trace :param = undef;
    field $cause :param = undef;

    ADJUST {
        if (defined $cause
            && !(Scalar::Util::blessed($cause) && $cause->isa('Temporalio::Exception'))) {
            require Temporalio::Exception::Argument;
            Temporalio::Exception::Argument->throw(
                message => 'cause must be a Temporalio::Exception instance',
            );
        }
        # ignore_class skips frames inside this class and its subclasses, so
        # the trace starts at the code that constructed or threw the exception.
        $stack_trace //= Devel::StackTrace->new(ignore_class => __PACKAGE__);
    }

    # Class method: construct and die in one step.
    sub throw ($class, %fields) {
        die $class->new(%fields);
    }

    method message     { $message }
    method stack_trace { $stack_trace }
    method cause       { $cause }

    # Message plus the recursively stringified cause chain, e.g.
    # "foo: caused by: bar: caused by: baz".
    method as_string () {
        return defined $cause ? "$message: caused by: " . $cause->as_string : $message;
    }
}

1;

__END__

=head1 NAME

Temporalio::Exception - base class for all Temporalio SDK exceptions

=head1 SYNOPSIS

    use Temporalio::Exception;

    Temporalio::Exception->throw(message => 'something failed');

    my $exc = Temporalio::Exception->new(
        message => 'outer',
        cause   => $inner_exception,
    );
    say "$exc";    # "outer: caused by: <inner message>"

=head1 DESCRIPTION

Every exception raised by the SDK is an instance of this class or one of
its C<Temporalio::Exception::*> subclasses. Instances carry a C<message>,
an optional C<cause> (which must itself be a Temporalio::Exception), and a
L<Devel::StackTrace> captured at construction unless one is supplied.
Stringification is overloaded to render the message followed by the full
cause chain.

=cut
