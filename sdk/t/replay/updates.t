# ABOUTME: Replay tests for DoUpdate handling in the Runner (spec section 19):
# ABOUTME: the two-phase update dispatch (sync read-only validator then async
# ABOUTME: tracked handler), the accepted/rejected/completed UpdateResponse
# ABOUTME: command sequence, buffer-then-drain for pre-instance updates, dynamic
# ABOUTME: dispatch, and the validator/handler failure routing (T-upd-1..11).
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

# The UpdateResponse variants on a WorkflowCommand: the runner emits one
# `update_response` command per phase. Return the response sub-message of a
# command, or undef when the command is not an update_response.
sub update_response_of ($cmd) {
    return undef unless $cmd->which_variant eq 'update_response';
    return $cmd->update_response;
}

# ---------------------------------------------------------------------------
# T-upd-1: an accepted update (non-mutating validator + sync handler returning a
# value) produces exactly [accepted, completed{result}] with the right
# protocol_instance_id, in one activation.
# ---------------------------------------------------------------------------
T2->subtest('accepted update emits accepted then completed (T-upd-1)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::UpdateCounter',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'UpdateCounter',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-1',
                name                 => 'add',
                input                => [ payload(5) ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 2, 'exactly two UpdateResponse commands');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'first UpdateResponse is accepted');
    T2->is($ur[1]->update_response->which_response, 'completed',
        'second UpdateResponse is completed');
    T2->is($ur[0]->update_response->protocol_instance_id, 'pi-1',
        'accepted carries the protocol_instance_id');
    T2->is($ur[1]->update_response->protocol_instance_id, 'pi-1',
        'completed carries the protocol_instance_id');
    T2->is($PC->from_payload($ur[1]->update_response->completed), 5,
        'completed carries the handler return value');
});

# ---------------------------------------------------------------------------
# T-upd-2: a validator that throws produces a single rejected{failure}, no
# accepted, and the workflow state is untouched.
# ---------------------------------------------------------------------------
T2->subtest('validator rejection emits a single rejected (T-upd-2)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::UpdateCounter',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'UpdateCounter',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-2',
                name                 => 'add',
                input                => [ payload(-3) ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 1, 'exactly one UpdateResponse command');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the single UpdateResponse is rejected');
    T2->is($ur[0]->update_response->protocol_instance_id, 'pi-2',
        'rejected carries the protocol_instance_id');
    T2->ok(defined $ur[0]->update_response->rejected,
        'rejected carries a failure');

    # The workflow keeps running (the body parked on its timer) — no fail/cancel.
    T2->ok(!(grep { $_->which_variant eq 'fail_workflow_execution' } @cmds),
        'the workflow was not failed');
});

# ---------------------------------------------------------------------------
# T-upd-3: no validator (or run_validator:false) -> accepted unconditionally
# before the handler. The addNoValidator handler has no paired validator.
# ---------------------------------------------------------------------------
T2->subtest('no validator -> accepted unconditionally (T-upd-3)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::UpdateCounter',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'UpdateCounter',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-3',
                name                 => 'addNoValidator',
                input                => [ payload(7) ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 2, 'accepted then completed');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'accepted (no validator registered)');
    T2->is($PC->from_payload($ur[1]->update_response->completed), 7,
        'completed with the handler result');
});

# ---------------------------------------------------------------------------
# T-upd-4: an async handler awaiting an activity: accepted in the first
# activation, the workflow is NOT completed while the handler Future is pending,
# and completed in the activation that resolves the activity.
# ---------------------------------------------------------------------------
T2->subtest('async handler accepts first, completes on resolve (T-upd-4)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::AsyncUpdater',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'AsyncUpdater',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-4',
                name                 => 'slowUpdate',
                input                => [ payload('Alice') ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur1 = grep { $_->which_variant eq 'update_response' } @first;
    T2->is(scalar @ur1, 1, 'only the accepted UpdateResponse in the first activation');
    T2->is($ur1[0]->update_response->which_response, 'accepted',
        'the handler accepted the update');
    T2->ok((grep { $_->which_variant eq 'schedule_activity' } @first),
        'the async handler scheduled its activity');
    T2->ok(!(grep { $_->which_variant eq 'complete_workflow_execution' } @first),
        'the workflow does NOT complete while the handler is in-flight');
    T2->ok(!$harness->runner->_all_handlers_finished,
        'the in-progress-handlers set tracks the update handler');

    # Resolve the activity: the handler resumes and completes.
    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { resolve_activity => {
                seq    => 1,
                result => { completed => { result => payload('hi Alice') } },
            } },
        ],
    }));

    my @ur2 = grep { $_->which_variant eq 'update_response' } @second;
    T2->is(scalar @ur2, 1, 'the completed UpdateResponse in the resolving activation');
    T2->is($ur2[0]->update_response->which_response, 'completed',
        'the handler completed');
    T2->is($PC->from_payload($ur2[0]->update_response->completed), 'got: hi Alice',
        'completed carries the awaited result');
    T2->ok($harness->runner->_all_handlers_finished,
        'the handler is no longer in-progress');
});

# ---------------------------------------------------------------------------
# T-upd-5: a handler that throws an ApplicationError post-acceptance produces
# rejected{failure}; the workflow is not failed.
# ---------------------------------------------------------------------------
T2->subtest('handler ApplicationError -> rejected post-accept (T-upd-5)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::FailingUpdater',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'FailingUpdater',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-5',
                name                 => 'appFail',
                input                => [ payload('x') ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 2, 'accepted then rejected');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'accepted (no validator)');
    T2->is($ur[1]->update_response->which_response, 'rejected',
        'the handler failure is a post-accept rejection');
    T2->ok(!(grep { $_->which_variant eq 'fail_workflow_execution' } @cmds),
        'the workflow was not failed');
});

# ---------------------------------------------------------------------------
# T-upd-6: a handler that plain-dies post-acceptance is a WORKFLOW TASK FAILURE,
# not a rejected update.
# ---------------------------------------------------------------------------
T2->subtest('handler plain die -> workflow task failure (T-upd-6)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::FailingUpdater',
    );

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'FailingUpdater',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-6',
                name                 => 'plainDie',
                input                => [ payload('x') ],
                run_validator        => 1,
            } },
        ],
    }));

    T2->is($completion->which_status, 'failed',
        'a plain die in the handler fails the workflow task');
});

# ---------------------------------------------------------------------------
# T-upd-7: a DoUpdate in the init activation (ordered before InitializeWorkflow)
# is buffered and dispatched after init.
# ---------------------------------------------------------------------------
T2->subtest('DoUpdate before init is buffered then dispatched (T-upd-7)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::UpdateCounter',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-7',
                name                 => 'add',
                input                => [ payload(9) ],
                run_validator        => 1,
            } },
            { initialize_workflow => {
                workflow_type => 'UpdateCounter',
                arguments     => [],
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 2, 'the buffered update was dispatched after init');
    T2->is($ur[0]->update_response->which_response, 'accepted', 'accepted');
    T2->is($PC->from_payload($ur[1]->update_response->completed), 9,
        'completed with the handler result');
});

# ---------------------------------------------------------------------------
# T-upd-8: an unknown update name on a live instance with no dynamic handler is
# an immediate rejection (no indefinite buffering, unlike signals).
# ---------------------------------------------------------------------------
T2->subtest('unknown update name -> immediate rejected (T-upd-8)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::UpdateCounter',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'UpdateCounter',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-8',
                name                 => 'noSuchUpdate',
                input                => [ payload(1) ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 1, 'a single UpdateResponse');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the unknown update is rejected immediately');
});

# ---------------------------------------------------------------------------
# T-upd-9: a dynamic handler receives ($name, @args), emits accepted/completed,
# and is not validated.
# ---------------------------------------------------------------------------
T2->subtest('dynamic update handler dispatch (T-upd-9)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DynamicUpdater',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DynamicUpdater',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-9',
                name                 => 'whatever',
                input                => [ payload('v') ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 2, 'accepted then completed');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the dynamic handler accepted (never validated)');
    T2->is($PC->from_payload($ur[1]->update_response->completed), 'whatever=v',
        'the dynamic handler got (name, @args)');
});

# ---------------------------------------------------------------------------
# T-upd-10: a validator that issues a command is a WORKFLOW TASK FAILURE (the
# read-only guard rejects the command).
# ---------------------------------------------------------------------------
T2->subtest('validator issuing a command -> task failure (T-upd-10)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::MutatingValidator',
    );

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'MutatingValidator',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-10',
                name                 => 'cmd',
                input                => [ payload('x') ],
                run_validator        => 1,
            } },
        ],
    }));

    T2->is($completion->which_status, 'failed',
        'a command-issuing validator fails the workflow task');
});

# ---------------------------------------------------------------------------
# T-upd-11: on replay run_validator is false — the validator is not invoked, but
# the accepted/completed sequence is reproduced exactly. Using the `add`
# handler whose validator would REJECT this delta if it ran (negative): with
# run_validator:false the validator is skipped and the update is accepted.
# ---------------------------------------------------------------------------
T2->subtest('replay run_validator:false reproduces accepted/completed (T-upd-11)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::UpdateCounter',
    );

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'UpdateCounter',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-11',
                name                 => 'add',
                input                => [ payload(-1) ],
                run_validator        => 0,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 2, 'accepted then completed (validator skipped on replay)');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'accepted without re-running the validator');
    T2->is($PC->from_payload($ur[1]->update_response->completed), -1,
        'completed with the handler result (negative delta accepted)');
});

# ---------------------------------------------------------------------------
# M1: with :Run returned while a handler is still in-flight, the runner WARNS
# and COMPLETES (warn-and-complete parity), and all_handlers_finished is a
# public predicate. Drive an async update whose handler is in-flight when :Run
# returns (a body that returns immediately).
# ---------------------------------------------------------------------------
T2->subtest('warn-and-complete with an in-flight handler (M1)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ReturningUpdater',
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ReturningUpdater',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-m1',
                name                 => 'slowUpdate',
                input                => [ payload('Alice') ],
                run_validator        => 1,
            } },
        ],
    }));

    # :Run returned immediately, but the update handler is still awaiting its
    # activity. The runner completes the workflow anyway and warns.
    T2->ok((grep { $_->which_variant eq 'complete_workflow_execution' } @cmds),
        'the workflow completes despite the in-flight handler (warn-and-complete)');
    T2->ok((grep { /unfinished|in-flight|in-progress|handler/i } @warnings),
        'a warning is emitted about the unfinished handler');

    # The public predicate is reachable from Temporalio::Workflow.
    T2->ok(Temporalio::Workflow->can('all_handlers_finished'),
        'Temporalio::Workflow::all_handlers_finished is public');
});

T2->done_testing;
