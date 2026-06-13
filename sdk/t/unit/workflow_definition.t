# ABOUTME: Unit tests for workflow definitions (spec sections 8.6, 10.1)
# ABOUTME: Covers :Run/:Signal/:Query/:Update/:Init registration, overrides, dupes, and the registry.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Workflow::Definition;
use Temporalio::Worker::WorkflowRegistry;
use Temporalio::Exception::Argument;

no warnings 'experimental::class';

# ---------------------------------------------------------------------------
# Fixture workflow classes. Each is declared with feature 'class' and inherits
# Temporalio::Workflow::Definition so the :Run/:Signal/:Query/:Update/:Init
# handlers (which live in the base, per the spec section 10.1 constraints)
# register the methods. Future::AsyncAwait is loaded; only ONE :isa class
# parses per file (lessons.md), so the extra fixtures with their own :isa live
# in t/lib/WfDef/*.pm (required below).
# ---------------------------------------------------------------------------

# A workflow with the full attribute surface. :Run is named "run" so the
# workflow type defaults to the class basename "Greeting" (spec section 8.6).
class WfDef::Greeting :isa(Temporalio::Workflow::Definition) {
    field $greeting = 'Hello';

    method init :Init ($name) { $greeting = "Hi"; return; }

    async method run :Run ($name) { return "$greeting, $name!"; }

    method change_greeting :Signal('changeGreeting') ($new) { $greeting = $new; return; }

    method current_greeting :Query ($) { return $greeting; }

    async method set_greeting :Update ($new) { $greeting = $new; return; }
}

# T-wf-defn: the per-class _workflow_defs registry is fully populated.
T2->subtest('full attribute surface registers in _workflow_defs' => sub {
    my $defs = WfDef::Greeting->_workflow_defs;

    T2->is(ref($defs->{run}), 'CODE', ':Run captured a code ref');

    # :Signal('changeGreeting') overrides the method name (explicit name).
    T2->is([sort keys %{ $defs->{signals} }], ['changeGreeting'],
        'signal registered under the explicit name');
    T2->is(ref($defs->{signals}{changeGreeting}), 'CODE', 'signal value is a code ref');

    # :Query with no argument defaults to the method name.
    T2->is([sort keys %{ $defs->{queries} }], ['current_greeting'],
        'query registered under the method name (default)');

    # :Update with no argument defaults to the method name.
    T2->is([sort keys %{ $defs->{updates} }], ['set_greeting'],
        'update registered under the method name (default)');

    # :Init registers the constructor hook.
    T2->is(ref($defs->{init}), 'CODE', ':Init captured a code ref');

    # The captured :Run ref is invocable on an instance and returns a Future
    # (spec section 10.1 registration contract).
    my $instance = WfDef::Greeting->new;
    my $ref = $defs->{run};
    my $f = $instance->$ref('World');
    T2->is($f->get, 'Hello, World!', 'captured :Run ref runs the workflow body');
});

# T-wf-defn: the workflow type name defaults to the class basename for a :Run
# method named "run", and is overridable via :Run('Custom'). These use their
# own :isa classes, so load them from t/lib.
require WfDef::CustomRun;       # :Run('CustomWorkflow')
require WfDef::Plain;           # :Run named "execute" (non-"run") -> method name

T2->subtest('workflow type defaults and overrides' => sub {
    T2->is(WfDef::Greeting->_workflow_type, 'Greeting',
        'run method -> class basename');
    T2->is(WfDef::CustomRun->_workflow_type, 'CustomWorkflow',
        ':Run(name) overrides the workflow type');
    T2->is(WfDef::Plain->_workflow_type, 'execute',
        'non-run :Run method -> the method name');
});

# Two :Run methods on one class are rejected at definition (compile) time.
# NOTE: the Definition handlers throw Temporalio::Exception::Argument, but a
# die that escapes a BEGIN-phase attribute handler during `require` is
# stringified by the Perl compiler ("...BEGIN failed--compilation aborted..."),
# so the blessed object cannot survive across the require boundary. The durable
# contract for compile-time detection is therefore the message; the blessed
# Argument object is asserted on the runtime registry path (T-wkr-2 below).
T2->subtest('two :Run methods are rejected at definition time' => sub {
    my $err = T2->dies(sub { require WfDef::TwoRuns });
    T2->ok($err, 'declaring a second :Run dies');
    T2->like("$err", qr/Multiple :Run methods found/,
        'the message reports the duplicate :Run');
});

# Two :Signal handlers with the same name are rejected at definition time.
T2->subtest('duplicate signal name is rejected at definition time' => sub {
    my $err = T2->dies(sub { require WfDef::DupSignal });
    T2->ok($err, 'declaring a duplicate signal name dies');
    T2->like("$err", qr/Multiple Signal methods found for dup/,
        'the message names the duplicated signal');
});

# ---------------------------------------------------------------------------
# Registry (spec section 8.6). Accepts workflow class names, builds
# { type => class }, requires exactly one :Run per class, rejects duplicates.
# ---------------------------------------------------------------------------

T2->subtest('registry builds type => class from class names' => sub {
    my $reg = Temporalio::Worker::WorkflowRegistry->new(
        workflows => ['WfDef::Greeting', 'WfDef::CustomRun'],
    );
    T2->is(
        [sort keys %{ $reg->definitions }],
        ['CustomWorkflow', 'Greeting'],
        'all workflow type names registered',
    );
    T2->is($reg->definition('Greeting'), 'WfDef::Greeting',
        'definition() returns the backing class for a type');
});

# T-wkr-2 (workflow side): duplicate workflow type names raise Argument.
T2->subtest('T-wkr-2: duplicate workflow type names raise Argument' => sub {
    # Greeting and an alias both resolve to type "Greeting".
    my $err = T2->dies(sub {
        Temporalio::Worker::WorkflowRegistry->new(
            workflows => ['WfDef::Greeting', 'WfDef::Greeting'],
        );
    });
    T2->ok($err, 'building a registry with a duplicate type dies');
    T2->ok(
        Scalar::Util::blessed($err) && $err->isa('Temporalio::Exception::Argument'),
        'the error is a Temporalio::Exception::Argument',
    );
    T2->like("$err", qr/Greeting/, 'the message names the duplicated type');
});

# A class missing a :Run method is invalid.
T2->subtest('a workflow class without :Run is rejected' => sub {
    my $err = T2->dies(sub {
        Temporalio::Worker::WorkflowRegistry->new(workflows => ['WfDef::NoRun']);
    });
    T2->ok(
        Scalar::Util::blessed($err) && $err->isa('Temporalio::Exception::Argument'),
        'a class with no :Run is rejected with Argument',
    );
    T2->like("$err", qr/[Rr]un/, 'the message mentions the missing run method');
});

# An invalid workflow entry (not a class name) raises Argument.
T2->subtest('invalid workflow entry raises Argument' => sub {
    my $err = T2->dies(sub {
        Temporalio::Worker::WorkflowRegistry->new(workflows => [ {} ]);
    });
    T2->ok(
        Scalar::Util::blessed($err) && $err->isa('Temporalio::Exception::Argument'),
        'a bare hashref is rejected with Argument',
    );
});

T2->done_testing;
