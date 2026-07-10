# ABOUTME: Fixture Nexus service for the handler-context capabilities test
# ABOUTME: (spec R89, nexus finding 4): namespace echo + shutdown waiters.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;
use Temporalio::Nexus;

package NexusDef::ContextCaps {
    # Cross-await observations for the test to inspect. The dynamically-scoped
    # $Temporalio::Nexus::CURRENT ends at the handler's first await (the
    # dispatcher's segfault guard), so post-resolve values exercise the
    # package-flag fallback path of is_worker_shutdown.
    our $OBSERVED;
}

class NexusDef::ContextCaps :isa(Temporalio::Nexus::Definition) {
    method svc :NexusService('caps-service') ($) { }

    # R89: the operation info carries the worker namespace (Python parity:
    # Info.namespace, nexus/_operation_context.py:85), reachable both through
    # the passed $ctx and the Temporalio::Nexus::info module helper.
    method echo_namespace :SyncOperation('echo-namespace') ($ctx, $x) {
        my $via_ctx    = $ctx->info->namespace    // '(undef)';
        my $via_helper = Temporalio::Nexus::info()->namespace // '(undef)';
        return "$via_ctx|$via_helper";
    }

    # R89: park on wait_for_worker_shutdown, recording is_worker_shutdown
    # before parking and after the waiter resolves.
    method wait_shutdown :SyncOperation('wait-shutdown') ($ctx, $x) {
        $NexusDef::ContextCaps::OBSERVED = {
            before => Temporalio::Nexus::is_worker_shutdown() ? 1 : 0,
        };
        my $wait = Temporalio::Nexus::wait_for_worker_shutdown();
        return $wait->then(sub {
            $NexusDef::ContextCaps::OBSERVED->{after} =
                Temporalio::Nexus::is_worker_shutdown() ? 1 : 0;
            return Future->done('shutdown-observed');
        });
    }

    # R89: the sync variant returns true immediately once shutdown has begun.
    method sync_wait :SyncOperation('sync-wait') ($ctx, $x) {
        my $rv = Temporalio::Nexus::wait_for_worker_shutdown_sync(5);
        return 'sync-wait:' . ($rv ? 1 : 0);
    }

    # R89: the sync variant returns false after its timeout expires when
    # shutdown has not begun.
    method sync_wait_timeout :SyncOperation('sync-wait-timeout') ($ctx, $x) {
        my $rv = Temporalio::Nexus::wait_for_worker_shutdown_sync(0.05);
        return 'sync-wait:' . ($rv ? 1 : 0);
    }
}

1;
