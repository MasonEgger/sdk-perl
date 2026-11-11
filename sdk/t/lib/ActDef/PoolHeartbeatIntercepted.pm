# ABOUTME: Fixture activity class for step I7 direction B: a sync (fork-pool)
# ABOUTME: activity that heartbeats with STRUCTURED details (a hashref and a
# ABOUTME: string), so a test can assert a parent-side ActivityOutbound
# ABOUTME: interceptor observes the same Perl-level values, not opaque bytes.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Activity ();
use Temporalio::Activity::Definition;

class ActDef::PoolHeartbeatIntercepted :isa(Temporalio::Activity::Definition) {
    method run :Defn('PoolHeartbeatIntercepted', 'sync=1') () {
        Temporalio::Activity::heartbeat({ pct => 50 }, 'halfway');
        return 'done';
    }
}

1;
