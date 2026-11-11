# ABOUTME: Fixture activity class for step F6 (fork-pool frame pairing must be
# ABOUTME: token-exact): a sync (fork-pool) activity that records three
# ABOUTME: heartbeats chosen so the 'hbd'/'hb' frame pair can only stay matched
# ABOUTME: if the child sends the raw details AFTER the encode succeeds. The
# ABOUTME: first detail freezes but does not convert (encode dies), the second
# ABOUTME: converts but does not freeze (no 'hbd' of its own), the third
# ABOUTME: survives both.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Activity ();
use Temporalio::Activity::Definition;
use Temporalio::Payload::RawBytes ();

class ActDef::PoolHeartbeatPairing :isa(Temporalio::Activity::Definition) {
    method run :Defn('PoolHeartbeatPairing', 'sync=1') () {
        # 1. A SCALAR ref: Storable freezes it, so the raw-details relay
        #    lands, but no payload converter handles it, so the encode
        #    dies and no 'hb' frame follows. The body catches that, the
        #    way a body recovering from a bad detail would.
        eval {
            Temporalio::Activity::heartbeat(\'first-detail-unconvertible');
            1;
        };

        # 2. A RawBytes instance: the converter encodes it (binary/plain)
        #    but Storable cannot freeze a `feature 'class'` instance, so
        #    the best-effort raw-details relay is lost and this 'hb' frame
        #    arrives with no 'hbd' of its own. Pre-F6 it paired with the
        #    details heartbeat 1 parked.
        Temporalio::Activity::heartbeat(
            Temporalio::Payload::RawBytes->new(bytes => 'second-detail'));

        # 3. A plain string: both frames land, so this is the ONE heartbeat
        #    the parent's outbound chain is entitled to observe.
        Temporalio::Activity::heartbeat('third-detail');
        return 'done';
    }
}

1;
