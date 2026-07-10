# ABOUTME: Fixture workflow whose :Run prologue's FIRST statement snapshots the
# ABOUTME: state its :Signal handlers mutate — drives the init-activation
# ABOUTME: signals-before-main ordering assertion (R26) in init_signal_ordering.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;

# The :Run body's first statement reads @events and returns the snapshot
# synchronously (no awaits), so the returned value captures exactly what the
# prologue could see. Signal-with-start parity (spec R26): handlers for signals
# delivered in the initializing activation must have run before that first
# statement, so the snapshot carries their side effects. Two named handlers
# with distinct prefixes make cross-name arrival order observable.
class WfDef::InitSignalProbe :isa(Temporalio::Workflow::Definition) {
    field @events;

    async method run :Run () {
        my $snapshot = @events ? join(',', @events) : 'empty';
        return $snapshot;
    }

    method note :Signal('note') ($value) {
        push @events, "note:$value";
        return;
    }

    method mark :Signal('mark') ($value) {
        push @events, "mark:$value";
        return;
    }
}

1;
