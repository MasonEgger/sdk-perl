# ABOUTME: Integration workflow carrying a :VersioningBehavior('pinned')
# ABOUTME: attribute (spec §29.1). Used by deployment_versioning.t to confirm a
# ABOUTME: deployment-versioned worker reports the per-workflow behavior in its
# ABOUTME: activation completion and still routes/completes normally.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::VersionedGreeter :isa(Temporalio::Workflow::Definition) {
    async method run :Run :VersioningBehavior('pinned') ($name = 'World') {
        return "Hello, $name!";
    }
}

1;
