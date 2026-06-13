# ABOUTME: Unit tests for activity definitions (spec sections 8.5, 9.1, 9.2)
# ABOUTME: Covers :Defn registration, name override, FunctionDefinition, and the registry.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Activity::Definition;
use Temporalio::Activity::FunctionDefinition;
use Temporalio::Worker::ActivityRegistry;
use Temporalio::Exception::Argument;

no warnings 'experimental::class';

# ---------------------------------------------------------------------------
# Fixture activity classes. Each is declared with feature 'class' and inherits
# Temporalio::Activity::Definition so the :Defn handler (which lives in the
# base, per the spec section 10.1 constraints) registers the methods.
# Future::AsyncAwait is loaded; only ONE :isa class parses per file, so the
# extra fixtures with their own :isa live in t/lib/ActDef/*.pm (required below).
# ---------------------------------------------------------------------------

# T-act-1: default name = method-name-or-class-basename for a method named run.
class ActDef::SayHello :isa(Temporalio::Activity::Definition) {
    async method run :Defn ($name) {
        return "Hello, $name!";
    }
}

# T-act-1: _activity_defs returns { SayHello => $methodref } where the name is
# the class basename because the decorated method is named "run".
T2->subtest('T-act-1: class with :Defn registers basename for run method' => sub {
    my $defs = ActDef::SayHello->_activity_defs;
    T2->is([sort keys %$defs], ['SayHello'], 'registered under class basename "SayHello"');
    T2->is(ref($defs->{SayHello}{code}), 'CODE', 'value carries a code ref');

    # The captured method ref is invocable on an instance (spec section 10.1
    # registration contract).
    my $instance = ActDef::SayHello->new;
    my $ref = $defs->{SayHello}{code};
    my $f = $instance->$ref('World');
    T2->is($f->get, 'Hello, World!', 'captured method ref runs the activity body');
});

# T-act-2 / T-act-3 use their own :isa classes; load them from t/lib.
require ActDef::CustomName;     # T-act-2
require ActDef::TwoDefns;       # T-act-3

T2->subtest('T-act-2: :Defn(name) overrides the registered name' => sub {
    my $defs = ActDef::CustomName->_activity_defs;
    T2->is([sort keys %$defs], ['Custom'], 'registered under the explicit name');
});

T2->subtest('T-act-3: two :Defn methods on one class both register' => sub {
    my $defs = ActDef::TwoDefns->_activity_defs;
    T2->is([sort keys %$defs], ['first', 'second'], 'both decorated methods registered');
    T2->is(ref($defs->{first}{code}),  'CODE', 'first carries a code ref');
    T2->is(ref($defs->{second}{code}), 'CODE', 'second carries a code ref');
});

# T-act-4: FunctionDefinition->new(name => ..., code => ...)
T2->subtest('T-act-4: FunctionDefinition registers a function activity' => sub {
    my $sender = Temporalio::Activity::FunctionDefinition->new(
        name => 'send_email',
        code => async sub ($to, $subject, $body) { return "$to/$subject/$body" },
    );
    T2->is($sender->name, 'send_email', 'name accessor returns the explicit name');
    T2->is(ref($sender->code), 'CODE', 'code accessor returns the code ref');
    T2->is($sender->no_thread_cancellation, 0, 'no_thread_cancellation defaults to 0');

    my $f = $sender->code->('a', 'b', 'c');
    T2->is($f->get, 'a/b/c', 'the code ref runs');

    # name is mandatory.
    my $err = T2->dies(sub { Temporalio::Activity::FunctionDefinition->new(code => async sub {}) });
    T2->ok($err, 'missing name dies');

    # no_thread_cancellation is honored when passed.
    my $nc = Temporalio::Activity::FunctionDefinition->new(
        name => 'x', code => async sub {}, no_thread_cancellation => 1,
    );
    T2->is($nc->no_thread_cancellation, 1, 'no_thread_cancellation passes through');
});

# ---------------------------------------------------------------------------
# Registry (spec section 8.5). Accepts class names, instances, and
# FunctionDefinition objects; builds { type => callable }; rejects duplicates.
# ---------------------------------------------------------------------------

T2->subtest('registry builds type => callable from mixed inputs' => sub {
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'send_email', code => async sub { 'sent' },
    );
    my $reg = Temporalio::Worker::ActivityRegistry->new(
        activities => ['ActDef::SayHello', ActDef::TwoDefns->new, $fn],
    );

    T2->is(
        [sort keys %{ $reg->definitions }],
        ['SayHello', 'first', 'second', 'send_email'],
        'all activity type names registered',
    );
});

# T-wkr-2: duplicate activity type names raise Exception::Argument.
T2->subtest('T-wkr-2: duplicate activity type names raise Argument' => sub {
    my $a = Temporalio::Activity::FunctionDefinition->new(name => 'dup', code => async sub {});
    my $b = Temporalio::Activity::FunctionDefinition->new(name => 'dup', code => async sub {});
    my $err = T2->dies(sub { Temporalio::Worker::ActivityRegistry->new(activities => [$a, $b]) });
    T2->ok($err, 'building a registry with a duplicate name dies');
    T2->ok(
        Scalar::Util::blessed($err) && $err->isa('Temporalio::Exception::Argument'),
        'the error is a Temporalio::Exception::Argument',
    );
    T2->like("$err", qr/dup/, 'the message names the duplicated type');
});

# An invalid activity (not a class/instance/FunctionDefinition) raises Argument.
T2->subtest('invalid activity entry raises Argument' => sub {
    my $err = T2->dies(sub { Temporalio::Worker::ActivityRegistry->new(activities => [ {} ]) });
    T2->ok(
        Scalar::Util::blessed($err) && $err->isa('Temporalio::Exception::Argument'),
        'a bare hashref is rejected with Argument',
    );
});

T2->done_testing;
