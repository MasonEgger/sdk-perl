# ABOUTME: Fixture Nexus service for T-nexus-11 — duplicate operation name (rejected).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Nexus::Definition;

# Two operations resolving to the SAME name must raise at compile time. This
# file is loaded inside an eval in the test (T-nexus-11) so the BEGIN-phase
# Exception::Argument is captured.
class NexusDef::DupOp :isa(Temporalio::Nexus::Definition) {
    method one :SyncOperation('dup') ($ctx, $x) { return $x }
    method two :SyncOperation('dup') ($ctx, $x) { return $x }
}

1;
