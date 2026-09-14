# ABOUTME: Fixture activity class for the I7 fix-loop iter 1 warn
# ABOUTME: temporal.storable-freeze-heartbeat-details: a sync (fork-pool)
# ABOUTME: activity that heartbeats a value Storable CANNOT freeze (a
# ABOUTME: `feature 'class'` instance, here Temporalio::Payload::RawBytes)
# ABOUTME: but the default payload converter CAN encode, isolating the
# ABOUTME: hbd-send freeze failure from an unrelated payload-conversion one.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Activity ();
use Temporalio::Activity::Definition;
use Temporalio::Payload::RawBytes ();

class ActDef::PoolHeartbeatUnfreezable :isa(Temporalio::Activity::Definition) {
    method run :Defn('PoolHeartbeatUnfreezable', 'sync=1') () {
        # Temporalio::Payload::RawBytes is a `feature 'class'` instance
        # (Storable dies "Can't store OBJECT items" on it, lessons.md), but
        # Converter::Payload::BinaryPlain encodes it fine (it matches
        # isa('Temporalio::Payload::RawBytes')), so this isolates the hbd
        # raw-Storable-send freeze failure from a genuine
        # payload-conversion failure.
        Temporalio::Activity::heartbeat(
            Temporalio::Payload::RawBytes->new(bytes => 'cannot-freeze-me'));
        return 'done';
    }
}

1;
