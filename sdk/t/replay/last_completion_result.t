# ABOUTME: Replay tests for the last-run carry-over accessors (spec R88;
# ABOUTME: parity audit, in-workflow finding 7): has_/get_last_completion_result
# ABOUTME: decode the InitializeWorkflow job's last_completion_result payload,
# ABOUTME: get_last_failure types the continued_failure; absent -> false/undef.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;

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

# Drive WfDef::LastRunReader through one init activation whose
# initialize_workflow job carries the given extra fields, and return the
# decoded snapshot hashref off the completion command (undef if the workflow
# did not complete).
sub run_reader ($init_extra) {
    my $h = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LastRunReader');
    my @cmds = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'LastRunReader',
            %$init_extra,
        } } ],
    }));
    my $done = one_of(\@cmds, 'complete_workflow_execution');
    return undef unless $done;
    return $PC->from_payload($done->complete_workflow_execution->result);
}

# ---------------------------------------------------------------------------
# A seeded last_completion_result decodes: has_last_completion_result is true
# and get_last_completion_result returns the converted previous-run result
# (Python workflow/_context.py:675,688; the payload converter's optional
# type-hint pass-through is documented on the accessor).
# ---------------------------------------------------------------------------
T2->subtest('seeded last_completion_result decodes (R88)' => sub {
    my $snap = run_reader({
        last_completion_result => { payloads => [ payload('prev-result') ] },
    });
    T2->ok($snap, 'the reader workflow completed') or return;

    T2->is($snap->{has}, 1,
        'has_last_completion_result is true with a seeded result');
    T2->is($snap->{result}, 'prev-result',
        'get_last_completion_result returns the decoded previous result');
    T2->is($snap->{failure}, undef,
        'get_last_failure is undef when only a result was carried over');
});

# ---------------------------------------------------------------------------
# A seeded continued_failure types: get_last_failure returns the previous
# run's failure converted to a typed Temporalio::Exception::* (Python
# workflow/_context.py:696 over init.continued_failure).
# ---------------------------------------------------------------------------
T2->subtest('seeded last failure returns the typed failure (R88)' => sub {
    my $snap = run_reader({
        continued_failure => {
            message                  => 'previous run failed',
            application_failure_info => { type => 'PrevBoom' },
        },
    });
    T2->ok($snap, 'the reader workflow completed') or return;

    T2->ok($snap->{failure}, 'get_last_failure returned a failure') or return;
    T2->is($snap->{failure}{class}, 'Temporalio::Exception::Application',
        'the failure converts to the typed Application exception');
    T2->is($snap->{failure}{type}, 'PrevBoom',
        'the application failure type survives conversion');
    T2->is($snap->{failure}{message}, 'previous run failed',
        'the failure message survives conversion');

    # No carried-over completion result on this run.
    T2->is($snap->{has}, 0,
        'has_last_completion_result is false with only a failure seeded');
    T2->is($snap->{result}, undef,
        'get_last_completion_result is undef with only a failure seeded');
});

# ---------------------------------------------------------------------------
# Edge: with NEITHER field on the init job, has_last_completion_result is
# false and both getters return undef (a first run has no carry-over).
# ---------------------------------------------------------------------------
T2->subtest('absent carry-over reports false/undef (R88)' => sub {
    my $snap = run_reader({});
    T2->ok($snap, 'the reader workflow completed') or return;

    T2->is($snap->{has}, 0,
        'has_last_completion_result is false with no carry-over');
    T2->is($snap->{result}, undef,
        'get_last_completion_result is undef with no carry-over');
    T2->is($snap->{failure}, undef,
        'get_last_failure is undef with no carry-over');
});

T2->done_testing;
