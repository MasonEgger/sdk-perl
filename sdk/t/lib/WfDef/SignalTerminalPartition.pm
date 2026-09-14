# ABOUTME: Fixture workflow that makes a :Signal handler claim the workflow
# ABOUTME: terminal command mid-activation and then lets LATER jobs in the SAME
# ABOUTME: activation push a state-mutating command and a query response after
# ABOUTME: it. Drives the spec R13 re-partition case of
# ABOUTME: t/replay/signal_handler_classification.t (spec F2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

# One activation carries, in job order: signal `app` (a sync handler throwing a
# Temporal failure, so the settlement pushes FailWorkflowExecution and claims
# the one-shot terminal slot), signal `work` (an async handler that pushes a
# StartTimer and parks), and a query (answered in job set 3, pushing a
# RespondToQuery). The raw command buffer therefore ends up as
# [Fail, StartTimer, RespondToQuery]: a sequence core rejects, because nothing
# may follow the workflow-terminal command.
#
# Spec R13 says the survivors are the handler RESPONSES; the state-mutating
# commands the server will never act on past the terminal are dropped. The
# :Run body parks forever so the body itself contributes no command.
class WfDef::SignalTerminalPartition :isa(Temporalio::Workflow::Definition) {
    field $never = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $never });
        return 'unreachable';
    }

    method app :Signal('app') () {
        Temporalio::Exception::Application->throw(
            message => 'app boom before the state-mutating command',
            type    => 'PartitionBoomError',
        );
        return;
    }

    async method work :Signal('work') () {
        await Temporalio::Workflow::sleep(60);
        return 'unreachable';
    }

    method peek :Query('peek') () {
        return 'peeked';
    }
}

1;
