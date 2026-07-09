# ABOUTME: Fixture workflow whose :Run snapshots the four per-activation info
# ABOUTME: accessors (history length/size, build id, CAN-suggested) once per
# ABOUTME: `probe` signal, so the R79 replay test can assert each accessor
# ABOUTME: tracks the values delivered by the activation being processed.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run takes one snapshot of the four per-activation accessors (spec R79;
# parity audit, in-workflow finding 3) after each `probe` signal, resuming
# inside the pump of the activation that delivered the signal, so snapshot N
# carries the values of activation N. Returns both snapshots after the second.
class WfDef::ActivationInfoProbe :isa(Temporalio::Workflow::Definition) {
    field $probes = 0;

    async method run :Run () {
        my @snapshots;
        for my $needed (1, 2) {
            await Temporalio::Workflow::wait_condition(sub { $probes >= $needed });
            push @snapshots, {
                history_length =>
                    Temporalio::Workflow::get_current_history_length(),
                history_size =>
                    Temporalio::Workflow::get_current_history_size(),
                build_id =>
                    Temporalio::Workflow::get_current_build_id(),
                continue_as_new_suggested =>
                    Temporalio::Workflow::is_continue_as_new_suggested(),
            };
        }
        return [@snapshots];
    }

    method probe :Signal('probe') () {
        $probes++;
        return;
    }
}

1;
