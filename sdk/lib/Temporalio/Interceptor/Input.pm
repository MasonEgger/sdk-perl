# ABOUTME: Base for all interceptor Input objects (spec section 27.1).
# ABOUTME: args/headers are writable; every other field is read-only (mutation dies).
use v5.38;
use warnings;

use Temporalio::Exception::Argument ();

# Temporalio::Interceptor::Input is the shared backing store for the typed
# Input classes (Temporalio::Client::Interceptor::Input::* and
# Temporalio::Worker::Interceptor::Input::*). It holds a flat hash of named
# values. Only the keys named in %WRITABLE (args, headers) may be reassigned
# after construction; any other write dies with an Exception::Argument
# (spec section 27.1 resolved decision: mutating a read-only field dies).
#
# Implemented as a classic blessed-hash rather than `feature 'class'`: the
# Input objects are simple data carriers whose constructors must accept an
# arbitrary field set, and `feature 'class'` rejects undeclared :param kwargs.
# The typed wrappers are empty subclasses; the SDK builds them on the
# outbound / inbound install paths and callers read/mutate args/headers.
package Temporalio::Interceptor::Input;

# Only these keys are writable post-construction (spec section 27.1).
my %WRITABLE = (args => 1, headers => 1);

# new(field => value, ...) — seed the backing store. headers defaults to an
# empty hashref and args to an empty arrayref when omitted, so interceptor
# bodies can always read/append without an undef check.
sub new ($class, %init) {
    $init{headers} //= {};
    $init{args}    //= [];
    return bless { %init }, $class;
}

# get($name) — read any field.
sub get ($self, $name) { $self->{$name} }

# set($name, $value) — write a field. Only args/headers are writable; any
# other field dies (spec section 27.1).
sub set ($self, $name, $value) {
    unless ($WRITABLE{$name}) {
        Temporalio::Exception::Argument->throw(
            message => "interceptor Input field '$name' is read-only");
    }
    $self->{$name} = $value;
    return $value;
}

# args / headers accessors: read with no arg, write with one arg.
sub args ($self, @v)    { @v ? $self->set(args => $v[0])    : $self->{args} }
sub headers ($self, @v) { @v ? $self->set(headers => $v[0]) : $self->{headers} }

# to_hash — snapshot of the backing store (used by the root impl to rebuild
# the underlying request after interceptors have run).
sub to_hash ($self) { return { %$self } }

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Interceptor::Input - base for interceptor Input objects

=head1 DESCRIPTION

The shared backing store for every C<Temporalio::*::Interceptor::Input::*>
class. C<args> and C<headers> are writable; all other fields are read-only and
mutating them throws L<Temporalio::Exception::Argument> (spec section 27.1).

=head1 METHODS

=head2 args

C<< $input->args >> reads the argument list (an arrayref);
C<< $input->args(\@new) >> replaces it.

=head2 headers

C<< $input->headers >> reads the C<< Str => Payload >> header map;
C<< $input->headers(\%new) >> replaces it.

=head2 get / set

C<< $input->get($name) >> reads any named field; C<< $input->set($name, $v) >>
writes one, throwing for read-only names.

=head2 to_hash

Returns a shallow copy of the backing store.

=cut
