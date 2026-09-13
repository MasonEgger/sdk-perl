# ABOUTME: Replay tests for the dynamic update handler's validator (spec R86,
# ABOUTME: I9, closes #9): a validator registered alongside a RUNTIME dynamic
# ABOUTME: update handler (Temporalio::Workflow->set_dynamic_update_handler)
# ABOUTME: must be honored, mirroring the named-handler read-only guard.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Converter::Payload;

no warnings 'experimental::class';

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# ---------------------------------------------------------------------------
# The dynamic handler and its validator are installed synchronously in the
# :Run body's prologue (before its first await). InitializeWorkflow drains any
# buffered pre-init updates BEFORE the :Run body starts (spec section 19.2 /
# Runner.pm _apply_initialize), so a DoUpdate ordered in the SAME activation as
# InitializeWorkflow would still see no dynamic handler registered. Each test
# therefore pushes a bare init activation first (letting the body run to its
# first await and register the handler+validator), then a SEPARATE activation
# carrying the DoUpdate.
# ---------------------------------------------------------------------------

# A validator that throws produces a single rejected{failure}: no accepted, no
# completed. The handler never runs.
T2->subtest('dynamic validator rejection emits a single rejected' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DynUpdateValidator',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DynUpdateValidator',
                arguments     => [],
            } },
        ],
    }));

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-1',
                name                 => 'whatever',
                input                => [ payload('reject-me') ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 1, 'exactly one UpdateResponse command');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the single UpdateResponse is rejected (the dynamic handler did not run)');
    T2->is($ur[0]->update_response->protocol_instance_id, 'pi-1',
        'rejected carries the protocol_instance_id');
    T2->ok(defined $ur[0]->update_response->rejected,
        'rejected carries a failure');
});

# An admitted argument passes the dynamic validator; the dynamic handler then
# runs and completes.
T2->subtest('dynamic validator admits, dynamic handler runs' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DynUpdateValidator',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DynUpdateValidator',
                arguments     => [],
            } },
        ],
    }));

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { do_update => {
                id                   => 'u-2',
                protocol_instance_id => 'pi-2',
                name                 => 'whatever',
                input                => [ payload('fine') ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 2, 'accepted then completed');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the admitted update is accepted');
    T2->is($ur[1]->update_response->which_response, 'completed',
        'the dynamic handler ran and completed');
    T2->is($PC->from_payload($ur[1]->update_response->completed),
        'whatever=fine|validator_saw=whatever=fine',
        'the dynamic handler got (name, @args), and the validator saw the '
        . 'SAME (name, @args) the handler did');
});

# A dynamic validator that issues a command is a WORKFLOW TASK FAILURE, matching
# the named-validator read-only guard (WfDef::MutatingValidator / T-upd-10).
T2->subtest('dynamic validator issuing a command -> task failure' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DynUpdateValidatorViolation',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DynUpdateValidatorViolation',
                arguments     => [],
            } },
        ],
    }));

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { do_update => {
                id                   => 'u-3',
                protocol_instance_id => 'pi-3',
                name                 => 'whatever',
                input                => [ payload('x') ],
                run_validator        => 1,
            } },
        ],
    }));

    T2->is($completion->which_status, 'failed',
        'a command-issuing dynamic validator fails the workflow task');
});

T2->done_testing;
