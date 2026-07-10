# ABOUTME: Replay tests for typed missing-argument errors in workflow context
# ABOUTME: (spec R55 / finding A14): execute_activity and execute_local_activity
# ABOUTME: called without an activity type raise Temporalio::Exception::Argument
# ABOUTME: at both audit sites (Runner.pm:451-453 and :579-581), asserted by
# ABOUTME: class (never by message), instead of the pre-R55 plain string dies.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;

my $PC = Temporalio::Converter::Payload->default;

# Run the ActivityOptionProbe fixture in the given mode and return the commands
# emitted by its single (InitializeWorkflow) activation.
sub run_probe ($mode) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityOptionProbe',
    );
    my $class =
        'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $harness->push_activation($class->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ActivityOptionProbe',
                arguments     => [ $PC->to_payload($mode) ],
            } },
        ],
    }));
}

# An error-probe mode completes the workflow with the class of what the call
# raised; assert it is exactly the typed argument class (assert by class, not
# message: the R55 acceptance criterion).
sub probe_raises_argument ($mode, $label) {
    T2->subtest($label => sub {
        my @commands = run_probe($mode);
        T2->is(scalar @commands, 1,
            'exactly one command emitted (nothing was scheduled)');
        T2->is($commands[0]->which_variant, 'complete_workflow_execution',
            'the probe workflow completes (the error was caught in-body)');
        my $caught = $PC->from_payload(
            $commands[0]->complete_workflow_execution->result);
        T2->is($caught, 'Temporalio::Exception::Argument',
            'the call raised Temporalio::Exception::Argument');
    });
}

# --------------------------------------------------------------------------
# A missing activity type raises the typed argument error at both audit sites:
# schedule_activity (Runner.pm:451-453) and schedule_local_activity (:579-581).
# Pre-R55 both were plain string dies, uncatchable by class.
# --------------------------------------------------------------------------
probe_raises_argument('act_missing_type',
    'execute_activity without an activity type raises the typed error');
probe_raises_argument('la_missing_type',
    'execute_local_activity without an activity type raises the typed error');

T2->done_testing;
