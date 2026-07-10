# ABOUTME: Replay tests for QueryWorkflow handling in the Runner (spec section
# ABOUTME: 10.3): query dispatch to :Query handlers returning a RespondToQuery
# ABOUTME: command (T-wf-4), a dying handler -> query-failed response (not a
# ABOUTME: workflow/task failure), dynamic-query fallback, and queries-last
# ABOUTME: ordering (a query observes state a same-activation signal mutated).
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

# Build a WorkflowActivation proto. The job list is the oneof-tagged hashref
# form the generated classes accept.
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
# T-wf-4: a QueryWorkflow job against an in-flight workflow runs the named
# :Query handler and emits a RespondToQuery command carrying the decoded result.
# The :Run body is parked on a long timer; the query observes its state without
# disturbing the run Future (the workflow does NOT complete).
# ---------------------------------------------------------------------------
T2->subtest('query returns current state without disturbing the run (T-wf-4)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::QueryGreeter',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'QueryGreeter',
                arguments     => [],
            } },
        ],
    }));
    T2->is(scalar @init, 1, 'init activation parks the body on its timer');
    T2->is($init[0]->which_variant, 'start_timer', 'run body parked on its timer');

    my @q = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { query_workflow => {
                query_id   => 'q-1',
                query_type => 'greeting',
                arguments  => [],
            } },
        ],
    }));

    T2->is(scalar @q, 1, 'the query activation emits exactly one command');
    my $cmd = respond_to_query(@q);
    T2->ok($cmd, 'a RespondToQuery command was emitted');
    T2->is($cmd->query_id, 'q-1', 'the response carries the query id');
    T2->is($cmd->which_variant, 'succeeded', 'the query succeeded');
    T2->is($PC->from_payload($cmd->succeeded->response), 'initial',
        'the response payload is the handler return value');

    # The workflow is NOT complete — the query did not disturb the run Future.
    T2->ok(
        !(grep { $_->which_variant eq 'complete_workflow_execution' } @q),
        'the query did not complete the workflow',
    );
});

# ---------------------------------------------------------------------------
# A dying query handler produces a RespondToQuery with the FAILED variant (a
# query failure), NOT a FailWorkflowExecution and NOT a task-failed completion.
# The workflow itself keeps running.
# ---------------------------------------------------------------------------
T2->subtest('a dying query handler produces a query failure, not a workflow failure' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::QueryGreeter',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'QueryGreeter',
                arguments     => [],
            } },
        ],
    }));

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { query_workflow => {
                query_id   => 'q-boom',
                query_type => 'boom',
                arguments  => [],
            } },
        ],
    }));

    T2->is($completion->which_status, 'successful',
        'the completion is successful (the query failure is a command, not a task failure)');

    my @cmds = $harness->commands_of($completion);
    my $cmd  = respond_to_query(@cmds);
    T2->ok($cmd, 'a RespondToQuery command was emitted for the dying handler');
    T2->is($cmd->query_id, 'q-boom', 'the failed response carries the query id');
    T2->is($cmd->which_variant, 'failed', 'the response carries the FAILED variant');
    T2->like($cmd->failed->message, qr/query handler exploded/,
        'the failure carries the handler error message');

    # No workflow-level failure or completion leaked out.
    T2->ok(
        !(grep {
            $_->which_variant eq 'fail_workflow_execution'
                || $_->which_variant eq 'complete_workflow_execution'
        } @cmds),
        'the dying query did not fail or complete the workflow',
    );
});

# ---------------------------------------------------------------------------
# An unmatched query name routes to the dynamic catch-all handler, which
# receives (name, @args) (mirrors sdk-python dynamic query (name, args)).
# ---------------------------------------------------------------------------
T2->subtest('unmatched query routes to the dynamic handler' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DynamicQueryGreeter',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DynamicQueryGreeter',
                arguments     => [],
            } },
        ],
    }));

    my @q = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { query_workflow => {
                query_id   => 'q-dyn',
                query_type => 'whatever',
                arguments  => [ payload('x') ],
            } },
        ],
    }));

    my $cmd = respond_to_query(@q);
    T2->ok($cmd, 'a RespondToQuery command was emitted');
    T2->is($cmd->query_id, 'q-dyn', 'the response carries the query id');
    T2->is($PC->from_payload($cmd->succeeded->response), 'whatever=x',
        'the dynamic handler received the query name and args');
});

# ---------------------------------------------------------------------------
# QUERIES-LAST: within a single activation, a query job is processed AFTER all
# other jobs (signals, resolutions) so the query observes the most up-to-date
# state. A SignalWorkflow and a QueryWorkflow in the SAME activation: the query
# must see the value the signal set.
# ---------------------------------------------------------------------------
T2->subtest('queries are processed after other jobs (queries-last)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::QueryGreeter',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'QueryGreeter',
                arguments     => [],
            } },
        ],
    }));

    # The query is listed FIRST in the activation, but the runner must order it
    # LAST so it observes the signal's mutation.
    my @q = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { query_workflow => {
                query_id   => 'q-last',
                query_type => 'greeting',
                arguments  => [],
            } },
            { signal_workflow => {
                signal_name => 'set',
                input       => [ payload('updated') ],
            } },
        ],
    }));

    my $cmd = respond_to_query(@q);
    T2->ok($cmd, 'a RespondToQuery command was emitted');
    T2->is($PC->from_payload($cmd->succeeded->response), 'updated',
        'the query observed the post-signal state (processed last)');
});

T2->done_testing;
