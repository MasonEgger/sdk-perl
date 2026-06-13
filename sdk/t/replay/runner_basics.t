# ABOUTME: Replay tests for the deterministic workflow Runner skeleton (spec
# ABOUTME: section 10.3): trivial complete (T-wf-11), now/time/is_replaying,
# ABOUTME: NoRunner outside a body, and seeded determinism (T-wf-10). No server.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Exception::Workflow::NoRunner;

no warnings 'experimental::class';

# Build a WorkflowActivation proto with the given run_id/timestamp/jobs. The
# job list is the oneof-tagged hashref form the generated classes accept
# (e.g. { initialize_workflow => { workflow_type => 'Constant' } }).
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# ---------------------------------------------------------------------------
# T-wf-11: a :Run that returns a constant. A single activation with one
# InitializeWorkflow job must produce exactly one CompleteWorkflowExecution
# command carrying the converted result.
# ---------------------------------------------------------------------------
T2->subtest('trivial workflow completes (T-wf-11)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Constant',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'Constant',
                arguments     => [
                    { metadata => { encoding => 'json/plain' }, data => '"Alice"' },
                ],
            } },
        ],
    }));

    T2->is(scalar @commands, 1, 'exactly one command emitted');

    my $cmd = $commands[0];
    T2->is($cmd->which_variant, 'complete_workflow_execution',
        'the command is CompleteWorkflowExecution');

    # The :Run returns the plain (non-UTF-8) string "Hello, Alice!". The spec
    # composite converter encodes a non-UTF-8 string as binary/plain raw bytes
    # (BinaryPlain wins ahead of the json/plain catch-all — spec section 5.2),
    # so the result payload carries the string verbatim under binary/plain.
    my $result_payload = $cmd->complete_workflow_execution->result;
    T2->is($result_payload->metadata->{encoding}, 'binary/plain',
        'result payload uses binary/plain encoding (non-UTF-8 string)');
    T2->is($result_payload->data, 'Hello, Alice!',
        'result payload carries the converted return value');

    # And it round-trips back to the original Perl value through the converter.
    require Temporalio::Converter::Payload;
    T2->is(
        Temporalio::Converter::Payload->default->from_payload($result_payload),
        'Hello, Alice!',
        'result payload round-trips to the run-body return value',
    );
});

# ---------------------------------------------------------------------------
# now / time / is_replaying come from the activation, never the OS clock.
# ---------------------------------------------------------------------------
T2->subtest('now/time/is_replaying come from the activation' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Clock',
    );

    my @commands = $harness->push_activation(activation({
        run_id       => 'run-clock',
        timestamp    => { seconds => 1_700_000_000, nanos => 0 },
        is_replaying => 1,
        jobs         => [
            { initialize_workflow => { workflow_type => 'Clock' } },
        ],
    }));

    T2->is(scalar @commands, 1, 'one completion command');
    my $payload = $commands[0]->complete_workflow_execution->result;

    require Temporalio::Converter::Payload;
    my $value = Temporalio::Converter::Payload->default->from_payload($payload);

    T2->is($value->{time}, 1_700_000_000, 'Workflow::time is the activation epoch');
    T2->is($value->{now_epoch}, 1_700_000_000,
        'Workflow::now is a DateTime at the activation timestamp');
    T2->is($value->{is_replaying}, 1, 'is_replaying reflects the activation flag');
    T2->is($value->{run_id}, 'run-clock', 'info.run_id is the activation run id');
    T2->is($value->{workflow_type}, 'Clock', 'info.workflow_type is the run type');
});

# ---------------------------------------------------------------------------
# Calling a Workflow:: context function outside a body raises NoRunner.
# ---------------------------------------------------------------------------
T2->subtest('context functions outside a body raise NoRunner' => sub {
    for my $fn (qw(info now time is_replaying random)) {
        my $err = T2->dies(sub {
            no strict 'refs';
            &{"Temporalio::Workflow::$fn"}();
        });
        T2->ok(
            Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::Workflow::NoRunner'),
            "Temporalio::Workflow::$fn outside a body raises NoRunner",
        ) or T2->diag("got: $err");
    }
});

# ---------------------------------------------------------------------------
# T-wf-10: the deterministic RNG is seeded from the start job's
# randomness_seed. Two runners with the same seed produce the same sequence;
# a different seed produces a different sequence.
# ---------------------------------------------------------------------------
T2->subtest('random is deterministic from randomness_seed (T-wf-10)' => sub {
    my sub run_with_seed ($seed) {
        my $harness = Temporalio::Test::WorkflowReplay->new(
            workflow_class => 'WfDef::Clock',
        );
        my @commands = $harness->push_activation(activation({
            run_id    => "run-$seed",
            timestamp => { seconds => 1 },
            jobs      => [
                { initialize_workflow => {
                    workflow_type   => 'Clock',
                    randomness_seed => $seed,
                } },
            ],
        }));
        require Temporalio::Converter::Payload;
        my $value = Temporalio::Converter::Payload->default
            ->from_payload($commands[0]->complete_workflow_execution->result);
        return $value->{rng};
    }

    my $a = run_with_seed(42);
    my $b = run_with_seed(42);
    my $c = run_with_seed(99);

    T2->is($a, $b, 'same seed -> identical RNG sequence');
    T2->isnt($a, $c, 'different seed -> different RNG sequence');
    T2->is(scalar @$a, 4, 'four draws captured');
});

T2->done_testing;
