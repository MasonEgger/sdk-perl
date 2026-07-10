# ABOUTME: Replay tests for the workflow metric meter (spec R83, parity
# ABOUTME: in-workflow finding 6): a counter recorded via
# ABOUTME: Temporalio::Workflow::metric_meter reaches the injected test buffer
# ABOUTME: on a live activation and is suppressed while the activation replays
# ABOUTME: (Python parity: workflow/_context.py:710 + _ReplaySafeMetricMeter).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use MetricBuffer ();
use Temporalio::Core::Proto;
use Temporalio::Runtime::MetricMeter ();
use Temporalio::Test::WorkflowReplay;

my $ACTIVATION_CLASS =
    'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';

# Drive one MetricEmitter activation (live or replaying) against a fresh
# buffer-backed meter; return (buffer, commands).
sub run_emitter (%opts) {
    my $buffer = MetricBuffer->new;
    my $meter  = Temporalio::Runtime::MetricMeter::Meter->new(
        backend => $buffer);
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::MetricEmitter',
        namespace      => 'test-ns',
        task_queue     => 'test-tq',
        metric_meter   => $meter,
    );
    my @commands = $harness->push_activation($ACTIVATION_CLASS->new({
        run_id       => 'r1',
        timestamp    => { seconds => 100 },
        is_replaying => ($opts{is_replaying} ? 1 : 0),
        jobs         => [
            { initialize_workflow => { workflow_type => 'MetricEmitter' } },
        ],
    }));
    return ($buffer, @commands);
}

T2->subtest('live activation: the counter add reaches the buffer' => sub {
    my ($buffer, @commands) = run_emitter(is_replaying => 0);

    T2->is(scalar @commands, 1, 'one command emitted');
    T2->is($commands[0]->which_variant, 'complete_workflow_execution',
        'the workflow completed');

    T2->is(scalar @{ $buffer->instruments }, 1, 'one instrument created');
    my $instrument = $buffer->instruments->[0];
    T2->is($instrument->{name}, 'wf_counter', 'instrument name');
    T2->is($instrument->{description}, 'R83 test counter',
        'instrument description');
    T2->is($instrument->{unit}, 'widgets', 'instrument unit');
    T2->is($instrument->{kind},
        Temporalio::Runtime::MetricMeter::Kind::COUNTER_INTEGER,
        'counter maps to the CounterInteger kind');

    T2->is(scalar @{ $buffer->records }, 1, 'exactly one value recorded');
    my $record = $buffer->records->[0];
    T2->is($record->{name},  'wf_counter', 'record targets the counter');
    T2->is($record->{value}, 1,            'recorded value');
    T2->is($record->{attrs}, {
        # The worker-context attribute set (Python parity:
        # _workflow_instance.py:1338-1352 workflow_metric_meter).
        namespace     => 'test-ns',
        task_queue    => 'test-tq',
        workflow_type => 'MetricEmitter',
        # The per-call attribute merged on top.
        phase         => 'run',
    }, 'context attributes and the per-call attribute merge');
});

T2->subtest('replaying activation: the add is suppressed' => sub {
    my ($buffer, @commands) = run_emitter(is_replaying => 1);

    T2->is(scalar @commands, 1, 'one command emitted');
    T2->is($commands[0]->which_variant, 'complete_workflow_execution',
        'the workflow still completes during replay');

    # Python parity: the replay-safe wrapper suppresses EMITS only; the
    # instrument itself is still created (exporters may register it).
    T2->is(scalar @{ $buffer->instruments }, 1,
        'the instrument is still created during replay');
    T2->is(scalar @{ $buffer->records }, 0,
        'no value is recorded during replay');
});

T2->done_testing;
