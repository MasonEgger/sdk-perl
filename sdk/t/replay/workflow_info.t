# ABOUTME: Replay tests for the workflow info() surface (spec R36 / finding A5):
# ABOUTME: workflow_id, attempt, task_queue carry init-activation/worker values
# ABOUTME: with Python-parity names, and the pre-R36 fields are unchanged.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;

# Build a WorkflowActivation proto (the oneof-tagged hashref form).
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# Drive WfDef::InfoReporter (whose :Run returns info() verbatim) through one
# init activation and decode the completion result back to the info hashref.
sub run_info_workflow (%harness_args) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::InfoReporter',
        %harness_args,
    );
    my @commands = $harness->push_activation(activation({
        run_id    => 'run-info-1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'InfoReporter',
                workflow_id   => 'wf-info-1',
                attempt       => 3,
            } },
        ],
    }));
    T2->is(scalar @commands, 1, 'one completion command');
    T2->is($commands[0]->which_variant, 'complete_workflow_execution',
        'the command is CompleteWorkflowExecution');
    return Temporalio::Converter::Payload->default
        ->from_payload($commands[0]->complete_workflow_execution->result);
}

# ---------------------------------------------------------------------------
# R36: the three previously-missing fields carry the init-activation values
# (workflow_id, attempt) and the worker's own queue (task_queue) — the same
# sourcing as Python's Info (sdk-python worker/_workflow.py: workflow_id and
# attempt from the InitializeWorkflow job, task_queue from the worker).
# ---------------------------------------------------------------------------
T2->subtest('workflow_id, attempt, task_queue carry init/worker values' => sub {
    my $info = run_info_workflow(
        namespace  => 'info-ns',
        task_queue => 'info-tq',
    );

    T2->is($info->{workflow_id}, 'wf-info-1',
        'info.workflow_id is the InitializeWorkflow workflow_id');
    T2->is($info->{attempt}, 3,
        'info.attempt is the InitializeWorkflow attempt');
    T2->is($info->{task_queue}, 'info-tq',
        'info.task_queue is the workflow execution task queue');
});

# ---------------------------------------------------------------------------
# The pre-R36 fields are unchanged: run_id, workflow_type, namespace, patches,
# search_attributes, memo all still ship with their existing values/shapes.
# ---------------------------------------------------------------------------
T2->subtest('the already-present info fields are unchanged' => sub {
    my $info = run_info_workflow(
        namespace  => 'info-ns',
        task_queue => 'info-tq',
    );

    T2->is($info->{run_id}, 'run-info-1', 'info.run_id is the activation run id');
    T2->is($info->{workflow_type}, 'InfoReporter',
        'info.workflow_type is the run type');
    T2->is($info->{namespace}, 'info-ns', 'info.namespace is the injected namespace');
    T2->is($info->{patches}, [], 'info.patches is the (empty) notified-patch list');
    T2->is($info->{search_attributes}, {},
        'info.search_attributes is the (empty) start-time view');
    T2->is($info->{memo}, {}, 'info.memo is the (empty) start-time view');
});

T2->done_testing;
