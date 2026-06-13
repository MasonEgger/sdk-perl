# ABOUTME: Integration fixture (P4.4) exercised end-to-end against a live dev
# ABOUTME: server: :Run waits for a :Signal to set the name, a :Query reads the
# ABOUTME: current name back, then the workflow greets and completes.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks on wait_condition until a `setName` signal sets the name, then
# returns a greeting built from it. While parked, a `currentName` query observes
# the in-flight state — before the signal it is the empty initial value, after
# the signal it is the name the client sent. This drives the full client path:
#   $handle->signal('setName', [$name])  -> SignalWorkflowExecution
#   $handle->query('currentName')        -> QueryWorkflow (decoded result)
# and, against a terminated run with reject_condition NOT_OPEN, QueryRejected.
class WfDef::SignalQueryGreeter :isa(Temporalio::Workflow::Definition) {
    field $name = '';

    async method run :Run('SignalQueryGreeter') () {
        await Temporalio::Workflow::wait_condition(sub { length $name });
        return "Hello, $name!";
    }

    method set_name :Signal('setName') ($value) {
        $name = $value;
        return;
    }

    method current_name :Query('currentName') () {
        return $name;
    }
}

1;
