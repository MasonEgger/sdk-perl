# ABOUTME: Fixture workflow whose :UpdateValidator is an ASYNC method that
# ABOUTME: suspends and never resolves, driving the F7 pending-Future guard
# ABOUTME: (validators must be synchronous) in dynamic_update_validator.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# An update validator is SYNCHRONOUS by contract: sdk-python calls it as
# `handler(*input.args)` with no await (_workflow_instance.py:2938-2945), so an
# `async def` validator there hands back an un-awaited coroutine that is merely
# truthy and the update is accepted unvalidated. Perl cannot detect an async
# sub up front, but it CAN see that the validator handed back a Future that is
# not ready, which is exactly the same mistake. The runner treats that as a
# validator error and rejects the update with a message naming the fix.
#
# The validator here awaits a bare Future that nothing ever completes, so it
# suspends at the await and returns a pending Future.
class WfDef::AsyncUpdateValidator :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        await Temporalio::Workflow::sleep(3600);
        return 'done';
    }

    method slow :Update('slow') (@args) {
        return 'the handler ran';
    }

    async method validate_slow :UpdateValidator('slow') (@args) {
        await Future->new;
        return;
    }
}

1;
