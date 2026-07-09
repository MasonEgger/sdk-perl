# ABOUTME: Fixture Nexus service for the dispatcher unit test (T-nexus-12/13/14).
# ABOUTME: sync success, workflow-run async, handler error, and operation error ops.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;
use Temporalio::Nexus::Definition;
use Temporalio::Nexus::WorkflowHandle ();
use Temporalio::Exception::NexusHandler ();
use Temporalio::Exception::Nexus::OperationError ();
use Temporalio::Exception::Application ();

class NexusDef::Handler :isa(Temporalio::Nexus::Definition) {
    method svc :NexusService('test-service') ($) { }

    # T-nexus-12: a sync operation returns the value directly.
    method say_hello :SyncOperation('say-hello') ($ctx, $name) {
        return "Hello, $name!";
    }

    # T-nexus-13: a workflow-run operation returns a Nexus WorkflowHandle. (The
    # dispatcher reads its token; this fixture builds the handle directly so the
    # test needs no live client.)
    async method run_wf :WorkflowRunOperation('run-wf') ($ctx, $input) {
        return Temporalio::Nexus::WorkflowHandle->new(
            namespace => 'default', workflow_id => "op-wf-$input");
    }

    # R32 (finding L20): an operation that parks on a pending future, exposed
    # in $NexusDef::Handler::PARKED so the cancel_task test can observe the
    # dispatcher cancelling it.
    method park :SyncOperation('park') ($ctx, $x) {
        return $NexusDef::Handler::PARKED = Future->new;
    }

    # T-nexus-14: a handler error carries a Nexus type.
    method bad_request :SyncOperation('bad-request') ($ctx, $x) {
        Temporalio::Exception::NexusHandler->throw(
            message => 'no good', type => 'BAD_REQUEST');
    }

    # T-nexus-14: an OperationError -> failure-carrying StartOperationResponse.
    method op_failed :SyncOperation('op-failed') ($ctx, $x) {
        Temporalio::Exception::Nexus::OperationError->throw(
            message => 'operation failed',
            state   => 'failed',
            cause   => Temporalio::Exception::Application->new(
                message => 'boom', type => 'BoomError'),
        );
    }
}

1;
