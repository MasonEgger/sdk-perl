# ABOUTME: Integration child workflow — greets its argument, or throws an
# ABOUTME: Application failure when asked, and records a signal it receives.
# ABOUTME: Used by the child_workflows integration test (T-child-13).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application;

# A small child workflow with three behaviours driven by its first argument:
#   'fail'   -> throw an Application failure (so the parent observes a
#               ChildWorkflow failure).
#   'signal' -> wait until a 'poke' signal arrives, then return the payload it
#               carried (so the parent can signal the child via the handle).
#   anything else -> return "Hello, <name>!".
class WfDef::E2EChild :isa(Temporalio::Workflow::Definition) {
    field $poked = undef;

    async method run :Run ($name = 'World') {
        if ($name eq 'fail') {
            Temporalio::Exception::Application->throw(
                message => 'child boom',
                type    => 'ChildBoom',
            );
        }
        if ($name eq 'signal') {
            await Temporalio::Workflow::wait_condition(sub { defined $poked });
            return "poked: $poked";
        }
        return "Hello, $name!";
    }

    method poke :Signal('poke') ($value = 'default') {
        $poked = $value;
        return;
    }
}

1;
