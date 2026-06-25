# ABOUTME: Worker tuner (spec §29.2): holds four slot suppliers (workflow,
# ABOUTME: activity, local_activity, nexus — WH-7's four pools). create_fixed /
# ABOUTME: create_resource_based factories plus a composite new. Each pool is a
# ABOUTME: Temporalio::Worker::SlotSupplier::* object; the worker reads them via
# ABOUTME: the *_slot_supplier accessors to pack the TemporalCoreTunerHolder.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();
use Temporalio::Worker::SlotSupplier::FixedSize ();
use Temporalio::Worker::SlotSupplier::ResourceBased ();

# The four-pool tuner holder. The pools map 1:1 onto TemporalCoreTunerHolder's
# workflow/activity/local_activity/nexus slot suppliers (header order). Each is
# a SlotSupplier object exposing _pack_spec.
class Temporalio::Worker::Tuner {
    field $workflow_slot_supplier       :param;
    field $activity_slot_supplier       :param;
    field $local_activity_slot_supplier :param;
    field $nexus_task_slot_supplier     :param;

    ADJUST {
        for my $pair (
            [workflow_slot_supplier       => $workflow_slot_supplier],
            [activity_slot_supplier       => $activity_slot_supplier],
            [local_activity_slot_supplier => $local_activity_slot_supplier],
            [nexus_task_slot_supplier     => $nexus_task_slot_supplier],
        ) {
            my ($name, $supplier) = @$pair;
            Temporalio::Exception::Argument->throw(
                message => "Tuner $name must be a SlotSupplier with _pack_spec")
                unless defined $supplier
                    && ref $supplier
                    && $supplier->can('_pack_spec');
        }
    }

    method workflow_slot_supplier       { $workflow_slot_supplier }
    method activity_slot_supplier       { $activity_slot_supplier }
    method local_activity_slot_supplier { $local_activity_slot_supplier }
    method nexus_task_slot_supplier     { $nexus_task_slot_supplier }

    # suppliers() -> the four pools in holder order (workflow, activity,
    # local_activity, nexus). The worker iterates these to pack the holder.
    method suppliers {
        return (
            $workflow_slot_supplier,
            $activity_slot_supplier,
            $local_activity_slot_supplier,
            $nexus_task_slot_supplier,
        );
    }

    # create_fixed(workflow_slots =>, activity_slots =>, local_activity_slots =>,
    # nexus_task_slots =>) -> a Tuner with four FixedSize suppliers. This is the
    # v0.1-parity tuner the worker synthesizes from max_concurrent_* when no
    # explicit tuner is given.
    sub create_fixed ($class, %slots) {
        return $class->new(
            workflow_slot_supplier =>
                Temporalio::Worker::SlotSupplier::FixedSize->new(
                    num_slots => $slots{workflow_slots}),
            activity_slot_supplier =>
                Temporalio::Worker::SlotSupplier::FixedSize->new(
                    num_slots => $slots{activity_slots}),
            local_activity_slot_supplier =>
                Temporalio::Worker::SlotSupplier::FixedSize->new(
                    num_slots => $slots{local_activity_slots}),
            nexus_task_slot_supplier =>
                Temporalio::Worker::SlotSupplier::FixedSize->new(
                    num_slots => $slots{nexus_task_slots}),
        );
    }

    # create_resource_based(target_memory_usage =>, target_cpu_usage =>,
    # workflow =>, activity =>, local_activity =>, nexus_task_slots =>) -> a
    # Tuner whose workflow/activity/local_activity pools are ResourceBased and
    # share the memory/CPU targets (sdk-python: all resource suppliers in one
    # tuner must agree on the targets). The nexus pool defaults to a FixedSize
    # supplier (WH-7). Each per-pool hash carries minimum_slots/maximum_slots/
    # ramp_throttle_ms; missing keys take the ResourceBased defaults.
    sub create_resource_based ($class, %args) {
        my $mem = $args{target_memory_usage};
        my $cpu = $args{target_cpu_usage};
        my $build = sub ($pool) {
            my %cfg = %{ $args{$pool} // {} };
            return Temporalio::Worker::SlotSupplier::ResourceBased->new(
                target_memory_usage => $mem,
                target_cpu_usage     => $cpu,
                %cfg,
            );
        };
        return $class->new(
            workflow_slot_supplier       => $build->('workflow'),
            activity_slot_supplier       => $build->('activity'),
            local_activity_slot_supplier => $build->('local_activity'),
            nexus_task_slot_supplier     =>
                Temporalio::Worker::SlotSupplier::FixedSize->new(
                    num_slots => $args{nexus_task_slots} // 100),
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::Tuner - worker slot-supplier tuner (four pools)

=head1 SYNOPSIS

    # Four FixedSize pools.
    my $tuner = Temporalio::Worker::Tuner->create_fixed(
        workflow_slots       => 100,
        activity_slots       => 100,
        local_activity_slots => 100,
        nexus_task_slots     => 100,
    );

    # Resource-based workflow/activity/local-activity, fixed nexus.
    my $tuner = Temporalio::Worker::Tuner->create_resource_based(
        target_memory_usage => 0.8,
        target_cpu_usage     => 0.9,
        workflow             => { minimum_slots => 5,  maximum_slots => 500 },
        activity             => { minimum_slots => 1,  maximum_slots => 500,
                                  ramp_throttle_ms => 50 },
        local_activity       => { minimum_slots => 1,  maximum_slots => 500,
                                  ramp_throttle_ms => 50 },
    );

    # Composite: mix supplier kinds per pool.
    my $tuner = Temporalio::Worker::Tuner->new(
        workflow_slot_supplier       => $a,
        activity_slot_supplier       => $b,
        local_activity_slot_supplier => $c,
        nexus_task_slot_supplier     => $d,
    );

=head1 DESCRIPTION

Holds the four slot suppliers a worker uses (spec §29.2). Pass a tuner to
C<< Temporalio::Worker->new(tuner => $tuner) >> instead of the legacy
C<max_concurrent_*> kwargs (the two are mutually exclusive).

=head1 METHODS

=head2 create_fixed

Factory: build a tuner with four C<FixedSize> suppliers from C<workflow_slots>,
C<activity_slots>, C<local_activity_slots>, and C<nexus_task_slots>.

=head2 create_resource_based

Factory: build a tuner whose workflow/activity/local-activity pools are
C<ResourceBased> (sharing C<target_memory_usage>/C<target_cpu_usage>) and whose
nexus pool is C<FixedSize>.

=head2 workflow_slot_supplier

The workflow-task slot supplier.

=head2 activity_slot_supplier

The activity slot supplier.

=head2 local_activity_slot_supplier

The local-activity slot supplier.

=head2 nexus_task_slot_supplier

The nexus-task slot supplier.

=head2 suppliers

The four pool suppliers in holder order (workflow, activity, local_activity,
nexus).

=cut
