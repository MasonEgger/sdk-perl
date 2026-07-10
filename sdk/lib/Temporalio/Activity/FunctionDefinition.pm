# ABOUTME: Function-based activity definition (spec section 9.2).
# ABOUTME: The single function-activity API — name + code ref, no module-level sugar.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Activity::FunctionDefinition {
    # field ... :reader needs Perl 5.40+; the SDK floor is 5.38, so declare
    # explicit reader methods below (lessons.md).
    field $name :param;
    field $code :param;
    field $no_thread_cancellation :param = 0;
    # Sync activities run in the IO::Async::Function fork pool (spec section
    # 9.4); async activities run on the main loop. The author declares this:
    # an `async sub` is async, a plain `sub` is sync. The flag drives the
    # dispatcher's pool-vs-loop routing (spec section 8.4 step 6).
    field $sync :param = 0;

    ADJUST {
        if (!defined $name || $name eq '') {
            require Temporalio::Exception::Argument;
            Temporalio::Exception::Argument->throw(
                message => 'FunctionDefinition requires a non-empty name',
            );
        }
        if (ref($code) ne 'CODE') {
            require Temporalio::Exception::Argument;
            Temporalio::Exception::Argument->throw(
                message => 'FunctionDefinition requires a code ref',
            );
        }
    }

    method name                   { $name }
    method code                   { $code }
    method no_thread_cancellation { $no_thread_cancellation }
    method sync                   { $sync }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Activity::FunctionDefinition - function-based activity definition

=head1 SYNOPSIS

    use Temporalio::Activity::FunctionDefinition;

    my $sender = Temporalio::Activity::FunctionDefinition->new(
        name => 'send_email',
        code => async sub ($to, $subject, $body) { ... },
        no_thread_cancellation => 0,
    );

    # Pass to Worker->new(activities => [ $sender, ... ]).

=head1 DESCRIPTION

The single way to register a function-based activity (spec section 9.2).
There is deliberately no module-level C<activity_defn> sugar (spec section 16
#9). The constructed object is passed in C<< Worker->new(activities => [...]) >>
just like a class-based activity.

C<name> (the activity type) and C<code> (the callable) are required; an
empty name or a non-code C<code> raises L<Temporalio::Exception::Argument>.
C<no_thread_cancellation> defaults to false.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Activity::FunctionDefinition->new(
        name => ...,
        code => ...,
        no_thread_cancellation => ...,
        sync => ...,
    );

Constructs a Temporalio::Activity::FunctionDefinition. Named parameters:

=over 4

=item C<name>

(required)

=item C<code>

(required)

=item C<no_thread_cancellation>

(optional, default C<0>)

=item C<sync>

(optional, default C<0>)

=back

=head1 METHODS

=head2 code

Accessor returning the C<code> value.

=head2 name

Accessor returning the C<name> value.

=head2 no_thread_cancellation

Accessor returning the C<no_thread_cancellation> value.

=head2 sync

Accessor returning the C<sync> value.

=cut
