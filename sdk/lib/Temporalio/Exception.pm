# ABOUTME: Base class for all Temporalio exceptions (spec section 6.1).
# ABOUTME: Carries message/stack_trace/cause; stringifies the full cause chain.
# ABOUTME: Also carries mutable SECONDARY errors (spec R62): failures raised
# ABOUTME: while this exception was being handled attach, never replace.
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

    # Errors raised while THIS exception was being handled or unwound (spec
    # R62, finding L32), e.g. a worker finalize die while a poll-loop error
    # is saved. They attach here (the Java suppressed-exceptions shape)
    # instead of replacing the primary error, so the original cause survives.
    # Unlike $cause, entries may be any exception object or plain string.
    field $secondary_errors = [];

    # Any defined value is accepted as a cause and stored as-is (spec R68,
    # finding A16; probe verify-45/pool-payload/probe_cause_mojibake.pl).
    # An earlier isa-check rejected non-Temporalio causes here, which dropped
    # the chain whenever an arbitrary die (a plain string, a Throwable or
    # Exception::Class object) was wrapped. The Python-parity contract is
    # __cause__: any raised value chains; the failure converter's plain-die
    # wrapper (Converter/Failure.pm to_failure, T-fail-4) handles the
    # non-exception shapes at the wire boundary.
    ADJUST {
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

    # attach_secondary($error): record a failure raised while handling this
    # exception (spec R62). Mutates in place so the caller keeps the primary
    # exception's class identity; returns $self for chaining.
    method attach_secondary ($error) {
        push @$secondary_errors, $error;
        return $self;
    }

    method secondary_errors { [@$secondary_errors] }

    # Message plus the recursively stringified cause chain, e.g.
    # "foo: caused by: bar: caused by: baz", then any attached secondary
    # errors, each as " [also failed: ...]". A non-Temporalio cause (spec
    # R68) renders through plain stringification with the trailing newline
    # chomped, so a verbatim die string reads cleanly in the chain.
    method as_string () {
        my $string = $message;
        if (defined $cause) {
            my $cause_text =
                Scalar::Util::blessed($cause)
                    && $cause->isa('Temporalio::Exception')
                ? $cause->as_string
                : do { my $text = "$cause"; chomp $text; $text };
            $string .= ": caused by: $cause_text";
        }
        for my $secondary (@$secondary_errors) {
            my $text = "$secondary";
            chomp $text;
            $string .= " [also failed: $text]";
        }
        return $string;
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
an optional C<cause>, and a L<Devel::StackTrace> captured at construction
unless one is supplied. Stringification is overloaded to render the message
followed by the full cause chain and any attached secondary errors.

=head2 The cause contract

Any defined value is accepted as a C<cause> and stored as-is (spec R68):

=over 4

=item *

A C<Temporalio::Exception> cause renders its own full chain inside
L</as_string>, giving C<"outer: caused by: inner: caused by: ...">.

=item *

Any other value - a plain string from an un-objected C<die>, or a foreign
error object from another exception system - is returned unchanged by the
L</cause> accessor and rendered in L</as_string> via ordinary
stringification with one trailing newline chomped.

=item *

At the wire boundary, L<Temporalio::Converter::Failure> wraps a
non-Temporalio cause as an Application failure: a plain string gets the
sentinel type C<Temporalio::Exception::Plain>, a foreign object its class
name. The chain therefore survives into the Failure proto.

=back

Instances also carry a mutable list of B<secondary errors> (spec R62): a
failure raised while this exception was being handled or unwound, such as a
worker finalize failure while a poll-loop error was pending, attaches via
L</attach_secondary> instead of replacing the primary error. This is the
analog of Java's suppressed exceptions; unlike C<cause>, an attached value
may be any exception object or plain string.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception->new(
        message => ...,
        stack_trace => ...,
        cause => ...,
    );

Constructs a Temporalio::Exception. Named parameters:

=over 4

=item C<message>

(required)

=item C<stack_trace>

(optional, default C<undef>)

=item C<cause>

(optional, default C<undef>; any defined value is accepted, see
L</The cause contract>)

=back

=head1 METHODS

=head2 as_string

Renders the message followed by the recursively stringified cause chain and
any attached secondary errors. Also invoked by string overloading.

=head2 attach_secondary

    $exception->attach_secondary($error);

Records a failure raised while this exception was being handled (spec R62,
finding L32), so it attaches to rather than replaces the primary error.
Mutates the instance in place and returns C<$self>. C<$error> may be any
exception object or plain string.

=head2 cause

Accessor returning the C<cause> value exactly as it was passed to the
constructor: a C<Temporalio::Exception>, a plain string, or a foreign
object per L</The cause contract>.

=head2 secondary_errors

Returns an array reference (a copy) of the errors attached via
L</attach_secondary>, in attachment order. Empty when none were attached.

=head2 message

Accessor returning the C<message> value.

=head2 stack_trace

Accessor returning the C<stack_trace> value.

=head2 throw

Class method that constructs an instance from the given fields and C<die>s with it in one step.

=cut
