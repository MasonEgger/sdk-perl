# ABOUTME: R13 (finding R9): a workflow-FAILURE completion must keep the query
# ABOUTME: and update responses buffered in the same activation and drop only
# ABOUTME: the state-mutating commands. Python ground truth (_set_workflow_failure,
# ABOUTME: ../sdk-python worker/_workflow_instance.py:2567): append fail, clear nothing.
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
use Temporalio::Converter::Payload;

no warnings 'experimental::class';

# Python ground truth, verified 2026-07-08 against
# ../sdk-python/temporalio/worker/_workflow_instance.py:
#   - _set_workflow_failure (:2567-2576) APPENDS fail_workflow_execution via
#     _add_command() to the already-accumulated successful.commands; it clears
#     NOTHING. Query responses (respond_to_query) and update responses
#     (update_response) buffered in the same activation therefore ride along
#     in Python's failure completion.
#   - The Perl runner additionally drops the state-mutating commands (e.g.
#     StartTimer), which the server never acts on past the fail — the spec R13
#     required behavior: responses survive, mutating commands are cleared.

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

sub commands_by_variant ($variant, @cmds) {
    return grep { ($_->which_variant // '') eq $variant } @cmds;
}

my $INIT_JOBS = [
    { initialize_workflow => {
        workflow_type => 'FailingResponder',
        arguments     => [],
    } },
];

# ---------------------------------------------------------------------------
# A query answered in the SAME activation as the workflow failure: queries are
# ordered last, so the handler responds after the body has already thrown; the
# failure completion must still carry the RespondToQuery command.
# ---------------------------------------------------------------------------
T2->subtest('query response survives a same-activation workflow failure' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::FailingResponder',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => $INIT_JOBS,
    }));
    T2->is(scalar @init, 0, 'the body parked on its wait_condition');

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'fail-now',
                input       => [],
            } },
            { query_workflow => {
                query_id   => 'q-1',
                query_type => 'status',
                arguments  => [],
            } },
        ],
    }));

    T2->is($completion->which_status, 'successful',
        'a workflow failure is a SUCCESSFUL completion (the task did not fail)');
    my @cmds = $harness->commands_of($completion);

    my @fail = commands_by_variant('fail_workflow_execution', @cmds);
    T2->is(scalar @fail, 1, 'the completion carries FailWorkflowExecution');
    T2->is($fail[0]->fail_workflow_execution->failure->message,
        'intentional workflow failure',
        'the fail command carries the thrown failure');

    my @rtq = commands_by_variant('respond_to_query', @cmds);
    T2->is(scalar @rtq, 1,
        'the query response SURVIVES the failure completion (R13)');
    return unless @rtq;
    T2->is($rtq[0]->respond_to_query->query_id, 'q-1',
        'the surviving response carries the query id');
    T2->is($PC->from_payload($rtq[0]->respond_to_query->succeeded->response),
        'answered', 'the surviving response carries the handler result');
});

# ---------------------------------------------------------------------------
# An update answered in the SAME activation as the workflow failure: the
# handler emits accepted + completed, then arms the failure the wait_condition
# pump observes. Both UpdateResponse commands must survive.
# ---------------------------------------------------------------------------
T2->subtest('update responses survive a same-activation workflow failure' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::FailingResponder',
    );

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r2',
        timestamp => { seconds => 100 },
        jobs      => [
            $INIT_JOBS->@*,
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-1',
                name                 => 'finish-and-fail',
                input                => [],
                run_validator        => 1,
            } },
        ],
    }));

    T2->is($completion->which_status, 'successful',
        'a workflow failure is a SUCCESSFUL completion (the task did not fail)');
    my @cmds = $harness->commands_of($completion);

    my @fail = commands_by_variant('fail_workflow_execution', @cmds);
    T2->is(scalar @fail, 1, 'the completion carries FailWorkflowExecution');

    my @ur = commands_by_variant('update_response', @cmds);
    T2->is(scalar @ur, 2,
        'both update responses SURVIVE the failure completion (R13)');
    return unless @ur == 2;
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the accepted response survives');
    T2->is($ur[1]->update_response->which_response, 'completed',
        'the completed response survives');
    T2->is($ur[1]->update_response->protocol_instance_id, 'pi-1',
        'the surviving responses carry the protocol_instance_id');
    T2->is($PC->from_payload($ur[1]->update_response->completed),
        'update-answered', 'completed carries the handler return value');
});

# ---------------------------------------------------------------------------
# State-mutating commands are still dropped: a signal buffers a StartTimer
# command and then arms the failure. The failure completion must carry the
# query response but NOT the StartTimer. (The drop assertions pass pre-fix and
# guard the GREEN partition; the response assertion is the RED.)
# ---------------------------------------------------------------------------
T2->subtest('state-mutating commands are still dropped from the failure completion' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::FailingResponder',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r3',
        timestamp => { seconds => 100 },
        jobs      => $INIT_JOBS,
    }));
    T2->is(scalar @init, 0, 'the body parked on its wait_condition');

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r3',
        timestamp => { seconds => 105 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'timer-then-fail',
                input       => [],
            } },
            { query_workflow => {
                query_id   => 'q-2',
                query_type => 'status',
                arguments  => [],
            } },
        ],
    }));

    T2->is($completion->which_status, 'successful',
        'a workflow failure is a SUCCESSFUL completion (the task did not fail)');
    my @cmds = $harness->commands_of($completion);

    T2->is(scalar commands_by_variant('start_timer', @cmds), 0,
        'the buffered StartTimer is dropped from the failure completion');
    T2->is(scalar commands_by_variant('fail_workflow_execution', @cmds), 1,
        'the completion carries exactly one FailWorkflowExecution');

    my @rtq = commands_by_variant('respond_to_query', @cmds);
    T2->is(scalar @rtq, 1,
        'the query response survives while the timer is dropped (the partition)');
});

T2->done_testing;
