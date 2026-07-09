# ABOUTME: Replay tests for the Workflow::memo / ::search_attributes readers
# ABOUTME: (spec R54, finding A6; archived v1 spec lines 1869-1870): both return
# ABOUTME: the initializing-activation values before an upsert and the updated
# ABOUTME: values after, as fresh copies, and raise NoRunner outside a body.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Converter::Payload;
use Temporalio::Common::SearchAttributeKey;
use Temporalio::Exception::Workflow::NoRunner;

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# Find the single command of a given variant.
sub one_of ($cmds, $variant) {
    my @hit = grep { $_->which_variant eq $variant } @$cmds;
    return $hit[0];
}

# ---------------------------------------------------------------------------
# The readers return the start-time values before an upsert and the updated
# values after (spec R54 acceptance criteria). WfDef::MemoSaReader snapshots
# both readers around an upsert of both and returns the snapshots as its
# result, so we decode them off the completion command.
# ---------------------------------------------------------------------------
T2->subtest('readers return initial then upserted values (R54)' => sub {
    my $key = Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField');
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::MemoSaReader');

    my @cmds = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'MemoSaReader',
            memo          => { fields => {
                reason => payload('initial'),
                stale  => payload('old'),
            } },
            search_attributes => { indexed_fields => {
                CustomKeywordField => $key->encode_value('start'),
            } },
        } } ],
    }));

    my $done = one_of(\@cmds, 'complete_workflow_execution');
    T2->ok($done, 'the reader workflow completed') or return;
    my $snap = $PC->from_payload($done->complete_workflow_execution->result);

    # Before the upsert: the initializing-activation values, Python-parity
    # shapes (a plain name -> converted-value hashref, like workflow.memo()
    # and the info search-attribute view in sdk-python).
    T2->is($snap->{before}{memo},
        { reason => 'initial', stale => 'old' },
        'memo() returns the start-time memo before the upsert');
    T2->is($snap->{before}{search_attributes},
        { CustomKeywordField => 'start' },
        'search_attributes() returns the start-time SAs before the upsert');

    # After the upsert: the set lands, the removal disappears.
    T2->is($snap->{after}{memo},
        { reason => 'updated' },
        'memo() reflects the upsert (set applied, removed key gone)');
    T2->is($snap->{after}{search_attributes},
        { CustomKeywordField => 'updated' },
        'search_attributes() reflects the upserted value');

    # Copy semantics: mutating a returned hashref must not leak into the
    # runner's view (the info() copy contract extends to the readers).
    T2->is($snap->{leaked}, 0,
        'both readers return fresh copies (no leak into the runner view)');
});

# ---------------------------------------------------------------------------
# Either reader outside a workflow body -> NoRunner (the Temporalio::Workflow::
# functional-surface contract).
# ---------------------------------------------------------------------------
T2->subtest('either reader outside a body raises NoRunner' => sub {
    my $e1 = T2->dies(sub { Temporalio::Workflow::memo() });
    T2->ok(Scalar::Util::blessed($e1)
        && $e1->isa('Temporalio::Exception::Workflow::NoRunner'),
        'memo outside a body raises NoRunner');

    my $e2 = T2->dies(sub { Temporalio::Workflow::search_attributes() });
    T2->ok(Scalar::Util::blessed($e2)
        && $e2->isa('Temporalio::Exception::Workflow::NoRunner'),
        'search_attributes outside a body raises NoRunner');
});

T2->done_testing;
