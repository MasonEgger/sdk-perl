# ABOUTME: Spec R14+R15 (findings A1/ADJ2): workflow_failure_exception_types and
# ABOUTME: nondeterminism_as_workflow_fail produce the SAME workflow-fail vs
# ABOUTME: task-fail outcome on the LIVE dispatcher path as on the replay
# ABOUTME: harness; the live path used to drop both options (live Runner
# ABOUTME: defaults), diverging from replay.
#
# Each scenario drives the same workflow die through BOTH paths (spec R14
# acceptance: "a replay test and a live-shaped test drive the same workflow
# die and assert the same outcome"):
#   - the replay harness (Test::WorkflowReplay, which always threaded the
#     options correctly), and
#   - a live-path WorkflowDispatcher, which pre-fix did not accept them at
#     all, so live Runners ran with defaults (finding A1 for the type list,
#     ADJ2 for the boolean).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Data ();
use Temporalio::Converter::Payload ();
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Worker::WorkflowDispatcher ();

no warnings 'experimental::class';

my $Activation = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_activation.WorkflowActivation');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_completion.WorkflowActivationCompletion');

my $PC = Temporalio::Converter::Payload->default;

sub activation ($args) { return $Activation->new($args) }

# WfDef::CustomFailer (a :Run method named `run`, so its workflow type is the
# class base name 'CustomFailer') throws WfDef::CustomError, a non-Temporal
# class: listed -> FailWorkflowExecution, unlisted -> task fail.
my $CUSTOM_FAILER_JOBS = [
    { initialize_workflow => { workflow_type => 'CustomFailer' } },
];

# WfDef::Plain (:Run type 'execute') plus a ResolveActivity for an unknown seq
# in the same activation: the canonical recorded-nondeterminism scenario
# (T-wf-13, mirrors t/replay/completion_outcomes.t).
my $NONDETERMINISM_JOBS = [
    { initialize_workflow => {
        workflow_type => 'execute',
        arguments     => [ $PC->to_payload(1) ],
    } },
    { resolve_activity => { seq => 99, result => { completed => {} } } },
];

# Dispatch one activation through a live-path dispatcher built with %options
# and return the decoded completion it sent.
sub live_completion ($workflow_class, $jobs, %options) {
    my @completions;
    my $dispatcher = Temporalio::Worker::WorkflowDispatcher->new(
        registry => Temporalio::Worker::WorkflowRegistry->new(
            workflows => [$workflow_class]),
        data_converter => Temporalio::Converter::Data->new,
        task_queue     => 'demo',
        %options,
        completer => sub ($bytes) {
            push @completions, $bytes;
            return Future->done;
        },
    );
    $dispatcher->dispatch_task(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => $jobs,
    })->encode)->get;
    T2->is(scalar @completions, 1, 'the live dispatcher sent one completion');
    return unless @completions == 1;
    return $Completion->decode($completions[0]);
}

# Run the same activation through the replay harness and return the completion.
sub replay_completion ($workflow_class, $jobs, %options) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => $workflow_class,
        %options,
    );
    return $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => $jobs,
    }));
}

# Assert a completion is a WORKFLOW failure: successful status whose sole
# command is FailWorkflowExecution carrying the message.
sub assert_workflow_failed ($completion, $message_re, $label) {
    T2->is($completion->which_status, 'successful',
        "$label: completion status is successful (workflow-level outcome)");
    my @commands = ($completion->successful->commands // [])->@*;
    T2->is(scalar @commands, 1, "$label: one command");
    return unless @commands == 1;
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        "$label: FailWorkflowExecution");
    T2->like($commands[0]->fail_workflow_execution->failure->message,
        $message_re, "$label: failure message preserved");
}

# Assert a completion is a workflow-TASK failure: the failed status (the
# server retries the task), carrying no commands.
sub assert_task_failed ($completion, $message_re, $label) {
    T2->is($completion->which_status, 'failed',
        "$label: completion status is failed (workflow-task failure)");
    T2->like($completion->failed->failure->message, $message_re,
        "$label: failure message preserved");
}

# ---------------------------------------------------------------------------
# R14: a listed non-Temporal exception class fails the WORKFLOW, on both
# paths.
# ---------------------------------------------------------------------------
T2->subtest('listed exception type fails the workflow on both paths (R14)' => sub {
    my %options = (workflow_failure_exception_types => ['WfDef::CustomError']);

    my $replay = replay_completion('WfDef::CustomFailer',
        $CUSTOM_FAILER_JOBS, %options);
    assert_workflow_failed($replay, qr/custom boom/, 'replay');

    my $live = live_completion('WfDef::CustomFailer',
        $CUSTOM_FAILER_JOBS, %options);
    return unless defined $live;
    assert_workflow_failed($live, qr/custom boom/, 'live');
});

# ---------------------------------------------------------------------------
# R14: the same die with the type UNLISTED fails only the TASK, on both
# paths.
# ---------------------------------------------------------------------------
T2->subtest('unlisted exception type fails the task on both paths (R14)' => sub {
    my $replay = replay_completion('WfDef::CustomFailer', $CUSTOM_FAILER_JOBS);
    assert_task_failed($replay, qr/custom boom/, 'replay');

    my $live = live_completion('WfDef::CustomFailer', $CUSTOM_FAILER_JOBS);
    return unless defined $live;
    assert_task_failed($live, qr/custom boom/, 'live');
});

# ---------------------------------------------------------------------------
# R15: recorded nondeterminism fails the WORKFLOW when
# nondeterminism_as_workflow_fail is set, on both paths.
# ---------------------------------------------------------------------------
T2->subtest('nondeterminism fails the workflow when configured, both paths (R15)' => sub {
    my %options = (nondeterminism_as_workflow_fail => 1);

    my $replay = replay_completion('WfDef::Plain',
        $NONDETERMINISM_JOBS, %options);
    assert_workflow_failed($replay, qr/99|non-?determin/i, 'replay');

    my $live = live_completion('WfDef::Plain',
        $NONDETERMINISM_JOBS, %options);
    return unless defined $live;
    assert_workflow_failed($live, qr/99|non-?determin/i, 'live');
});

# ---------------------------------------------------------------------------
# R15: without the flag the same nondeterminism fails only the TASK, on both
# paths.
# ---------------------------------------------------------------------------
T2->subtest('nondeterminism fails the task by default, both paths (R15)' => sub {
    my $replay = replay_completion('WfDef::Plain', $NONDETERMINISM_JOBS);
    assert_task_failed($replay, qr/99|non-?determin/i, 'replay');

    my $live = live_completion('WfDef::Plain', $NONDETERMINISM_JOBS);
    return unless defined $live;
    assert_task_failed($live, qr/99|non-?determin/i, 'live');
});

T2->done_testing;
