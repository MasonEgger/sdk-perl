# ABOUTME: Unit tests for spec R63 (finding A8): start_workflow accepts the archived
# ABOUTME: v1 spec section 7.4 workflow argument forms — type-name string, definition
# ABOUTME: class, or workflow function ref — each resolving to the workflow type name.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Client ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();

use WfDef::CustomRun ();   # :Run('CustomWorkflow') on a method named run
use WfDef::Plain ();       # :Run on a method named execute -> type 'execute'
use WfDef::NoRun ();       # Definition subclass with no :Run (unresolvable)

Temporalio::Core::Proto->load;

# A client built without a live connection: the request builder never touches
# the connection pointer, only namespace/identity/data_converter (same harness
# as start_workflow_request.t).
sub make_client {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-test',
        identity       => 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

sub build_type_name {
    my ($workflow) = @_;
    my $req = make_client()->_build_start_workflow_request(
        $workflow, [], id => 'wf-1', task_queue => 'q',
    )->get;
    return $req->workflow_type->name;
}

# ---------------------------------------------------------------------------
# Regression: the plain type-name string form is unchanged (v0.1 behavior).
# ---------------------------------------------------------------------------
T2->subtest('plain string form resolves verbatim (regression)' => sub {
    T2->is(build_type_name('MyWorkflow'), 'MyWorkflow',
        'string is the workflow type verbatim');
});

# ---------------------------------------------------------------------------
# Archived v1 spec section 7.4 form 1: a workflow definition class name
# resolves to the registered :Run type, not the class name itself.
# ---------------------------------------------------------------------------
T2->subtest('definition class form resolves to the registered type' => sub {
    T2->is(build_type_name('WfDef::CustomRun'), 'CustomWorkflow',
        ':Run(CustomWorkflow) class resolves to its custom type name');
    T2->is(build_type_name('WfDef::Plain'), 'execute',
        ':Run on method execute resolves to the method-name default');
});

# ---------------------------------------------------------------------------
# Archived v1 spec section 7.4 form 2: a workflow function ref (the :Run
# method ref) resolves through the definition registry.
# ---------------------------------------------------------------------------
T2->subtest('workflow function ref form resolves to the registered type' => sub {
    T2->is(build_type_name(WfDef::CustomRun->can('run')), 'CustomWorkflow',
        'run method ref resolves to the custom type name');
    T2->is(build_type_name(WfDef::Plain->can('execute')), 'execute',
        'execute method ref resolves to its type name');
});

# ---------------------------------------------------------------------------
# The signal_with_start variant shares the same resolution path.
# ---------------------------------------------------------------------------
T2->subtest('signal_with_start accepts the definition class form' => sub {
    my $req = make_client()->_build_signal_with_start_workflow_request(
        'WfDef::CustomRun', [],
        id => 'wf-s', task_queue => 'q',
        signal => 'greet', signal_args => ['hi'],
    )->get;
    T2->is($req->workflow_type->name, 'CustomWorkflow',
        'signal_with_start resolves the class to its type name');
});

# ---------------------------------------------------------------------------
# Unresolvable forms still raise the typed argument error pre-RPC.
# ---------------------------------------------------------------------------
T2->subtest('unresolvable forms raise Temporalio::Exception::Argument' => sub {
    my @bad = (
        [ 'unregistered coderef', sub { 42 } ],
        [ 'hashref',              {} ],
        [ 'undef',                undef ],
        [ 'empty string',         '' ],
        [ 'definition class with no :Run', 'WfDef::NoRun' ],
    );
    for my $case (@bad) {
        my ($label, $workflow) = @$case;
        my $err = T2->dies(sub {
            make_client()->_build_start_workflow_request(
                $workflow, [], id => 'wf-1', task_queue => 'q',
            )->get;
        });
        T2->ok($err && $err->isa('Temporalio::Exception::Argument'),
            "$label -> typed Argument error")
            or T2->diag("got: " . ($err // 'no error'));
    }
});

T2->done_testing;
