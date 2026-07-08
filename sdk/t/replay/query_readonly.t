# ABOUTME: Replay tests for the uniform read-only guard (finding R8 / step R24):
# ABOUTME: a :Query handler calling any of the four formerly-bypassing APIs
# ABOUTME: (patched, child-signal, external-signal, external-cancel) raises the
# ABOUTME: typed Temporalio::Exception::ReadOnly; writable-context use unchanged.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;

# Build a WorkflowActivation proto from the oneof-tagged hashref job form.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# Pull the single RespondToQuery (QueryResult) message out of a command list.
sub respond_to_query (@commands) {
    my ($cmd) = grep { $_->which_variant eq 'respond_to_query' } @commands;
    return defined $cmd ? $cmd->respond_to_query : undef;
}

# ---------------------------------------------------------------------------
# R24 main, table-driven across the four bypassing APIs (finding R8): a query
# handler runs in a read-only context, so a call to any command-emitting API
# raises the typed read-only error (Temporalio::Exception::ReadOnly, the
# sdk-python ReadOnlyContextError analog). The raise surfaces as a
# RespondToQuery FAILED response (Python parity: _apply_query_workflow catches
# the error like any other query death), the leaked command never reaches the
# completion, and the workflow itself keeps running.
# ---------------------------------------------------------------------------
my @READ_ONLY_CASES = (
    # [ probe api argument, action label in the error, leaked command variant ]
    ['patched',         'patched',                        'set_patch_marker'],
    ['child_signal',    'signal child workflow handle',   'signal_external_workflow_execution'],
    ['external_signal', 'signal external workflow handle','signal_external_workflow_execution'],
    ['external_cancel', 'cancel external workflow handle','request_cancel_external_workflow_execution'],
);

for my $case (@READ_ONLY_CASES) {
    my ($api, $label, $leak_variant) = @$case;

    T2->subtest("query calling $api raises the typed read-only error (R24)" => sub {
        my $harness = Temporalio::Test::WorkflowReplay->new(
            workflow_class => 'WfDef::ReadOnlyProber',
        );

        my @init = $harness->push_activation(activation({
            run_id    => 'r1',
            timestamp => { seconds => 100 },
            jobs      => [
                { initialize_workflow => {
                    workflow_type => 'ReadOnlyProber',
                    arguments     => [],
                } },
            ],
        }));
        T2->ok(
            (grep { $_->which_variant eq 'start_child_workflow_execution' } @init),
            'the body starts its child in the init activation',
        );

        # Resolve the child start so the query handler holds a live handle;
        # the body then parks on its long timer.
        my @resolved = $harness->push_activation(activation({
            run_id    => 'r1',
            timestamp => { seconds => 101 },
            jobs      => [
                { resolve_child_workflow_execution_start => {
                    seq => 1, succeeded => { run_id => 'child-run' },
                } },
            ],
        }));
        T2->ok(
            (grep { $_->which_variant eq 'start_timer' } @resolved),
            'the body parks on its timer after the child start resolves',
        );

        my $completion = $harness->push_activation_completion(activation({
            run_id    => 'r1',
            timestamp => { seconds => 105 },
            jobs      => [
                { query_workflow => {
                    query_id   => "q-$api",
                    query_type => 'probe',
                    arguments  => [ payload($api) ],
                } },
            ],
        }));

        # The read-only violation is a QUERY failure (Python parity), never a
        # task failure and never a workflow failure.
        T2->is($completion->which_status, 'successful',
            'the completion is successful (the violation fails the query, not the task)');

        my @cmds = $harness->commands_of($completion);
        my $cmd  = respond_to_query(@cmds);
        T2->ok($cmd, 'a RespondToQuery command was emitted');
        T2->is($cmd->query_id, "q-$api", 'the response carries the query id');
        T2->is($cmd->which_variant, 'failed',
            'the response carries the FAILED variant');
        T2->is($cmd->failed->application_failure_info->type,
            'Temporalio::Exception::ReadOnly',
            'the failure carries the typed read-only error class');
        T2->like($cmd->failed->message, qr/read-only context/,
            'the failure message names the read-only context');
        T2->like($cmd->failed->message, qr/\Q$label\E/,
            "the failure message names the attempted action ($label)");

        # The bypassing API's command must NOT leak out of the query.
        T2->is(
            scalar(grep { $_->which_variant eq $leak_variant } @cmds),
            0,
            "no leaked $leak_variant command in the query activation",
        );

        # The run itself is untouched: still parked, no terminal command.
        T2->is(
            scalar(grep {
                $_->which_variant eq 'complete_workflow_execution'
                    || $_->which_variant eq 'fail_workflow_execution'
            } @cmds),
            0,
            'the violation did not complete or fail the parked run',
        );
    });
}

# ---------------------------------------------------------------------------
# R24 writable arm: outside query context (a normal :Run in writable context)
# each of the four APIs still works exactly as before — the guard fires ONLY
# inside the read-only scope. Reuses the existing per-API fixtures.
# ---------------------------------------------------------------------------
T2->subtest('patched still works in writable context (R24)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Patcher',
    );
    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'Patcher',
                arguments     => [],
            } },
        ],
    }));
    T2->is(
        scalar(grep { $_->which_variant eq 'set_patch_marker' } @cmds),
        1, 'patched() emits its SetPatchMarker from writable context',
    );
});

T2->subtest('child-handle signal still works in writable context (R24)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildSignaller',
    );
    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ChildSignaller' } },
        ],
    }));
    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_child_workflow_execution_start => {
                seq => 1, succeeded => { run_id => 'run-abc' },
            } },
        ],
    }));
    my ($sig) = grep {
        $_->which_variant eq 'signal_external_workflow_execution'
    } @cmds;
    T2->ok(defined $sig, 'the child signal command is emitted from writable context');
    T2->is($sig->signal_external_workflow_execution->which_target,
        'child_workflow_id', 'the signal targets the child_workflow_id arm');
});

T2->subtest('external-handle signal still works in writable context (R24)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ExternalSignaller',
    );
    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalSignaller' } },
        ],
    }));
    T2->is(
        scalar(grep {
            $_->which_variant eq 'signal_external_workflow_execution'
        } @cmds),
        1, 'the external signal command is emitted from writable context',
    );
});

T2->subtest('external-handle cancel still works in writable context (R24)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ExternalCanceller',
    );
    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalCanceller' } },
        ],
    }));
    T2->is(
        scalar(grep {
            $_->which_variant eq 'request_cancel_external_workflow_execution'
        } @cmds),
        1, 'the external cancel command is emitted from writable context',
    );
});

T2->done_testing;
