# ABOUTME: R11 (finding R5): any die during activation processing must produce
# ABOUTME: a FAILED workflow-task completion — never an escaped die the poll
# ABOUTME: loop would warn-and-swallow (wedging the workflow until timeout).
# ABOUTME: Probe: a :Query handler returning a pending future (never resolves).
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
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Worker::WorkflowDispatcher ();

no warnings 'experimental::class';

my $Activation = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_activation.WorkflowActivation');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_completion.WorkflowActivationCompletion');

sub activation ($args) { return $Activation->new($args) }

my $INIT_JOBS = [
    { initialize_workflow => {
        workflow_type => 'PendingQuery',
        arguments     => [],
    } },
];

my $QUERY_JOBS = [
    { query_workflow => {
        query_id   => 'q-pending',
        query_type => 'pending',
        arguments  => [],
    } },
];

# ---------------------------------------------------------------------------
# Runner level (the R5 probe): a :Query handler returning a pending future
# makes the runner's `->result` read croak. process_activation must map that
# die to a failed workflow-task completion, not let it escape.
# ---------------------------------------------------------------------------
T2->subtest('a die during activation processing yields a failed completion (R5 probe)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::PendingQuery',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => $INIT_JOBS,
    }));
    T2->is($init[0]->which_variant, 'start_timer', 'run body parked on its timer');

    my $completion = eval {
        $harness->push_activation_completion(activation({
            run_id    => 'r1',
            timestamp => { seconds => 105 },
            jobs      => $QUERY_JOBS,
        }));
    };
    T2->ok(defined $completion, 'process_activation did not die')
        or T2->diag("escaped die: $@");
    return unless defined $completion;

    T2->is($completion->which_status, 'failed',
        'the completion is a workflow-TASK failure');
    T2->is($completion->run_id, 'r1', 'the failed completion carries the run_id');
    T2->like($completion->failed->failure->message, qr/is not yet (?:ready|complete)/,
        'the failure carries the underlying error message');
});

# ---------------------------------------------------------------------------
# Dispatcher level, same probe end to end: the completion contract with core
# is one completion per activation. dispatch_task must RESOLVE (not fail) and
# must have SENT a failed completion through the completer.
# ---------------------------------------------------------------------------
T2->subtest('the dispatcher sends the failed completion for the probe activation' => sub {
    my @completions;
    my $dispatcher = Temporalio::Worker::WorkflowDispatcher->new(
        registry => Temporalio::Worker::WorkflowRegistry->new(
            workflows => ['WfDef::PendingQuery']),
        data_converter => Temporalio::Converter::Data->new,
        task_queue     => 'demo',
        completer      => sub ($bytes) {
            push @completions, $bytes;
            return Future->done;
        },
    );

    $dispatcher->dispatch_task(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => $INIT_JOBS,
    })->encode)->get;
    T2->is(scalar @completions, 1, 'init activation completed');

    my $f = $dispatcher->dispatch_task(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => $QUERY_JOBS,
    })->encode);
    T2->ok(!$f->is_failed, 'dispatch_task resolved rather than failing')
        or T2->diag('dispatch failure: ' . (($f->failure)[0] // ''));
    T2->is(scalar @completions, 2,
        'a completion was sent for the failed activation');
    return unless @completions == 2;

    my $completion = $Completion->decode($completions[1]);
    T2->is($completion->which_status, 'failed', 'the sent completion is failed');
    T2->is($completion->run_id, 'r1', 'run_id present on the failed completion');
    T2->like($completion->failed->failure->message, qr/is not yet (?:ready|complete)/,
        'failure content carries the underlying error');
});

# ---------------------------------------------------------------------------
# Dispatcher-level error (no runner yet): an activation for an unregistered
# workflow type used to escape as a Bridge die. It must map to a failed
# completion the same way — the catch-all covers pre-runner failures too.
# ---------------------------------------------------------------------------
T2->subtest('a pre-runner dispatch error also maps to a failed completion' => sub {
    my @completions;
    my $dispatcher = Temporalio::Worker::WorkflowDispatcher->new(
        registry => Temporalio::Worker::WorkflowRegistry->new(
            workflows => ['WfDef::PendingQuery']),
        data_converter => Temporalio::Converter::Data->new,
        task_queue     => 'demo',
        completer      => sub ($bytes) {
            push @completions, $bytes;
            return Future->done;
        },
    );

    my $f = $dispatcher->dispatch_task(activation({
        run_id    => 'r-unreg',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'NoSuchWorkflow',
                arguments     => [],
            } },
        ],
    })->encode);
    T2->ok(!$f->is_failed, 'dispatch_task resolved rather than failing')
        or T2->diag('dispatch failure: ' . (($f->failure)[0] // ''));
    T2->is(scalar @completions, 1, 'a completion was sent');
    return unless @completions == 1;

    my $completion = $Completion->decode($completions[0]);
    T2->is($completion->which_status, 'failed', 'the completion is failed');
    T2->is($completion->run_id, 'r-unreg', 'run_id present');
    T2->like($completion->failed->failure->message, qr/not registered/,
        'failure message names the unregistered type error');
});

T2->done_testing;
