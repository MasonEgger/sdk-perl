# ABOUTME: Replay tests for Temporalio::Workflow::uuid4 (spec R77, parity audit
# ABOUTME: in-workflow finding 1): valid v4 shape, replay-stable, unique within
# ABOUTME: a run, and seeded from the activation randomness_seed. No server.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;

# R77 code trace: Workflow.pm:72 exposes random() but (pre-fix) no uuid4; the
# only UUID code was the client-side, non-deterministic
# Temporalio::Client::_new_uuid (Client.pm:754-763), which is not workflow-safe.
# Python parity: workflow/_context.py:866 builds
#   uuid.UUID(bytes=random().getrandbits(16 * 8).to_bytes(16, "big"), version=4)
# i.e. 128 bits drawn from the SAME deterministic RNG that random() returns,
# with the version nibble forced to 4 and the variant bits to RFC 4122 10xx.

# Canonical lowercase v4 shape: version nibble is literal 4, variant nibble is
# one of 8/9/a/b (the 10xx variant bits Python's uuid.UUID(version=4) forces).
my $V4_RE = qr/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# Run WfDef::UuidCaller once with the given randomness_seed; returns the
# { first, second } hashref its :Run produced. A fresh harness per call, so a
# repeat call with the same seed models replaying the same run from history.
my sub run_with_seed ($seed) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::UuidCaller',
    );
    my @commands = $harness->push_activation(activation({
        run_id    => "run-uuid-$seed",
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => {
                workflow_type   => 'UuidCaller',
                randomness_seed => $seed,
            } },
        ],
    }));
    T2->is(scalar @commands, 1, 'one completion command') or return {};
    T2->is($commands[0]->which_variant, 'complete_workflow_execution',
        'the command is CompleteWorkflowExecution') or return {};
    require Temporalio::Converter::Payload;
    return Temporalio::Converter::Payload->default
        ->from_payload($commands[0]->complete_workflow_execution->result);
}

# ---------------------------------------------------------------------------
# uuid4() returns a syntactically valid v4 UUID: version nibble 4, RFC 4122
# variant bits, canonical lowercase 8-4-4-4-12 form.
# ---------------------------------------------------------------------------
T2->subtest('uuid4 returns a syntactically valid v4 UUID' => sub {
    my $value = run_with_seed(42);
    T2->like($value->{first}, $V4_RE,
        'first uuid4 is canonical v4 (version nibble 4, variant 10xx)');
    T2->like($value->{second}, $V4_RE,
        'second uuid4 is canonical v4 (version nibble 4, variant 10xx)');
});

# ---------------------------------------------------------------------------
# A second uuid4() call in the same run differs from the first (the RNG
# advances; Python's getrandbits stream does the same).
# ---------------------------------------------------------------------------
T2->subtest('a second uuid4 in the same run differs from the first' => sub {
    my $value = run_with_seed(42);
    T2->isnt($value->{first}, $value->{second},
        'two uuid4 calls in one run produce distinct values');
});

# ---------------------------------------------------------------------------
# Stable across replay of the same run: re-driving the same activation (same
# randomness_seed) reproduces the identical UUID sequence.
# ---------------------------------------------------------------------------
T2->subtest('uuid4 is stable across replay of the same run' => sub {
    my $a = run_with_seed(42);
    my $b = run_with_seed(42);
    T2->is($a->{first}, $b->{first},
        'replaying the run reproduces the first uuid4');
    T2->is($a->{second}, $b->{second},
        'replaying the run reproduces the second uuid4');
});

# ---------------------------------------------------------------------------
# Seeded from the activation randomness seed: a different seed yields a
# different sequence (so the value provably derives from randomness_seed, not
# OS entropy or a fixed constant).
# ---------------------------------------------------------------------------
T2->subtest('uuid4 derives from the activation randomness seed' => sub {
    my $a = run_with_seed(42);
    my $c = run_with_seed(99);
    T2->isnt($a->{first}, $c->{first},
        'a different randomness_seed produces a different first uuid4');
    T2->isnt($a->{second}, $c->{second},
        'a different randomness_seed produces a different second uuid4');
});

T2->done_testing;
