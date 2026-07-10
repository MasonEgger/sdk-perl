# ABOUTME: Replay tests for the per-activation workflow info accessors (spec R79
# ABOUTME: / parity in-workflow finding 3): get_current_history_length/size,
# ABOUTME: get_current_build_id, is_continue_as_new_suggested track each
# ABOUTME: activation's delivered values (Python workflow/_context.py:140-185).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;

# Build a WorkflowActivation proto with the given fields. The job list is the
# oneof-tagged hashref form the generated classes accept.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

# Drive WfDef::ActivationInfoProbe through two probe-signal activations built
# from the given top-level field sets and return the two decoded snapshots.
# The fixture's `probe` handler snapshots the four accessors per activation;
# :Run parks until both snapshots exist, then returns them.
sub run_probe ($first_fields, $second_fields) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivationInfoProbe',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'run-act-info',
        timestamp => { seconds => 100 },
        jobs      => [
            { signal_workflow => { signal_name => 'probe' } },
            { initialize_workflow => {
                workflow_type => 'ActivationInfoProbe',
                workflow_id   => 'wf-act-info',
                arguments     => [],
            } },
        ],
        %$first_fields,
    }));
    T2->is(scalar @first, 0, 'no command after the first probe: :Run still parked');

    my @second = $harness->push_activation(activation({
        run_id    => 'run-act-info',
        timestamp => { seconds => 110 },
        jobs      => [
            { signal_workflow => { signal_name => 'probe' } },
        ],
        %$second_fields,
    }));
    T2->is(scalar @second, 1, 'one completion command after the second probe');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'the command is CompleteWorkflowExecution');

    my $snapshots = $PC->from_payload(
        $second[0]->complete_workflow_execution->result);
    T2->is(scalar @$snapshots, 2, 'the run recorded one snapshot per activation');
    return @$snapshots;
}

# ---------------------------------------------------------------------------
# R79: each accessor returns the value delivered by the CURRENT activation
# (history_length, history_size_bytes, deployment_version_for_current_task's
# build_id, continue_as_new_suggested), and a second activation with changed
# values updates all four: the per-activation capture Python does at the
# activate() boundary (_workflow_instance.py:427-429) and surfaces through
# workflow/_context.py:140,165,175,185.
# ---------------------------------------------------------------------------
T2->subtest('the four accessors track each activation\'s delivered values' => sub {
    my ($snap1, $snap2) = run_probe(
        {
            history_length            => 12,
            history_size_bytes        => 2048,
            continue_as_new_suggested => 0,
            deployment_version_for_current_task => { build_id => 'build-one' },
        },
        {
            history_length            => 34,
            history_size_bytes        => 8192,
            continue_as_new_suggested => 1,
            deployment_version_for_current_task => {
                deployment_name => 'deploy-a',
                build_id        => 'build-two',
            },
        },
    );

    T2->is($snap1, {
        history_length            => 12,
        history_size              => 2048,
        build_id                  => 'build-one',
        continue_as_new_suggested => 0,
    }, 'first activation: every accessor returns the delivered value');

    T2->is($snap2, {
        history_length            => 34,
        history_size              => 8192,
        build_id                  => 'build-two',
        continue_as_new_suggested => 1,
    }, 'second activation: every accessor reflects the updated values');
});

# ---------------------------------------------------------------------------
# Defaults: an activation that omits all four fields yields the Python-parity
# zero values: 0 lengths/sizes, false CAN-suggested, and an EMPTY-STRING build
# id (workflow_get_current_build_id returns "" when the activation carries no
# deployment_version_for_current_task, _workflow_instance.py:1195-1198).
# ---------------------------------------------------------------------------
T2->subtest('accessors return the zero defaults when the fields are absent' => sub {
    my ($snap1, $snap2) = run_probe({}, {});

    my $defaults = {
        history_length            => 0,
        history_size              => 0,
        build_id                  => '',
        continue_as_new_suggested => 0,
    };
    T2->is($snap1, $defaults, 'field-less first activation: all-zero defaults');
    T2->is($snap2, $defaults, 'field-less second activation: all-zero defaults');
});

T2->done_testing;
