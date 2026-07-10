# ABOUTME: Exception cause-chaining tests (spec R68, finding A16): any defined
# ABOUTME: value survives as a cause, so wrapping an arbitrary die keeps the
# ABOUTME: chain, stringifies without dying, and encodes over the wire.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Exception;
use Temporalio::Converter::Data;

# Adapted from probe verify-45/pool-payload/probe_cause_mojibake.pl - the
# cause-chaining half; the R57 UTF-8 half lives in converter_errors.t.
# Before the R68 fix, the ADJUST block at Exception.pm:29-36 rejected any
# cause that was not a Temporalio::Exception with a typed Argument throw,
# so wrapping an arbitrary die (a plain string or a foreign error object
# from Throwable, Exception::Class, etc.) dropped the chain entirely.

# A foreign exception class with a string overload, standing in for any
# non-Temporalio error object a user's dependencies might throw.
package Foreign::Error::Overloaded {
    use overload q{""} => sub { 'foreign: ' . $_[0]->{detail} }, fallback => 1;
    sub new { my ($class, %fields) = @_; return bless {%fields}, $class }
}

# The bare-bless shape: no string overload at all.
package Foreign::Error::Plain {
    sub new { return bless {}, shift }
}

T2->subtest('a plain string die survives as a cause (R68)' => sub {
    my $wrapper;
    T2->ok(T2->lives(sub {
        $wrapper = Temporalio::Exception->new(
            message => 'outer',
            # The verbatim shape of an un-objected Perl death.
            cause   => "inner death at foo.pl line 7.\n",
        );
    }), 'construction accepts a plain string cause');
    T2->is($wrapper->cause, "inner death at foo.pl line 7.\n",
        'the cause accessor returns the die string as-is');
    T2->is("$wrapper", 'outer: caused by: inner death at foo.pl line 7.',
        'stringification includes the chomped string cause');
});

T2->subtest('a foreign object survives as a cause, identity preserved (R68)' => sub {
    my $foreign = Foreign::Error::Overloaded->new(detail => 'db gone');
    my $wrapper;
    T2->ok(T2->lives(sub {
        $wrapper = Temporalio::Exception->new(
            message => 'outer',
            cause   => $foreign,
        );
    }), 'construction accepts a foreign error object');
    T2->ref_is($wrapper->cause, $foreign,
        'the cause accessor returns the exact object, not a copy or wrapper');
    T2->is("$wrapper", 'outer: caused by: foreign: db gone',
        'stringification goes through the foreign string overload');

    my $plain = Foreign::Error::Plain->new;
    my $bare = Temporalio::Exception->new(message => 'outer', cause => $plain);
    T2->ref_is($bare->cause, $plain, 'a non-overloaded object is stored as-is');
    my $string;
    T2->ok(T2->lives(sub { $string = "$bare" }),
        'stringifying a non-overloaded foreign cause does not die');
    T2->like($string, qr/\Aouter: caused by: Foreign::Error::Plain=HASH/,
        'a non-overloaded foreign cause renders as its default ref string');
});

T2->subtest('Temporalio::Exception causes still chain recursively (regression)' => sub {
    my $inner = Temporalio::Exception->new(message => 'inner');
    my $outer = Temporalio::Exception->new(message => 'outer', cause => $inner);
    T2->ref_is($outer->cause, $inner, 'exception cause identity unchanged');
    T2->is("$outer", 'outer: caused by: inner',
        'exception causes render via the full as_string chain');
});

# End-to-end: a non-exception cause reaches the wire through the failure
# converter's existing plain-die wrapper (T-fail-4), so the chain that used
# to be dropped at construction now survives all the way into the proto.
T2->subtest('non-exception causes encode through the failure converter (R68)' => sub {
    my $dc = Temporalio::Converter::Data->new;
    my $wrapper;
    T2->ok(T2->lives(sub {
        $wrapper = Temporalio::Exception->new(
            message => 'outer',
            cause   => "inner death\n",
        );
    }), 'construction accepts the string cause');
    my $failure = $dc->to_failure($wrapper)->get;
    T2->is($failure->message, 'outer', 'wrapper message reaches the wire');
    my $cause = $failure->cause;
    T2->ok(defined $cause, 'the wire failure carries the cause');
    T2->is($cause->message, 'inner death',
        'the chomped die message survives to the wire');
    T2->is($cause->which_failure_info, 'application_failure_info',
        'the string cause encodes as an Application failure');
    T2->is($cause->application_failure_info->type,
        'Temporalio::Exception::Plain',
        'the plain-die sentinel type marks it (T-fail-4)');
});

T2->done_testing;
