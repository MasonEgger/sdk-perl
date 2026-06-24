# ABOUTME: Fixture Nexus service for T-nexus-11 — explicit :NexusService + op names.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Nexus::Definition;

class NexusDef::CustomNames :isa(Temporalio::Nexus::Definition) {
    method svc :NexusService('custom-service') ($) { }

    method say_hello :SyncOperation('say-hello') ($ctx, $name) {
        return "Hello, $name!";
    }

    async method echo :WorkflowRunOperation('echo-op') ($ctx, $input) {
        return $input;
    }
}

1;
