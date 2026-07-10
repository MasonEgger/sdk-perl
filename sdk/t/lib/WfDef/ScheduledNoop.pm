# ABOUTME: Schedule integration fixture (P8.2): a trivial workflow that returns
# ABOUTME: its argument verbatim, so a schedule can start it without needing an
# ABOUTME: activity worker or any external state.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Noop workflow: echo the first argument (default 'arg1'). Scheduled runs of
# this type let the schedule integration test poll num_actions and inspect the
# action args without standing up an activity.
class WfDef::ScheduledNoop :isa(Temporalio::Workflow::Definition) {
    async method run :Run('ScheduledNoop') ($value = 'arg1') {
        return $value;
    }
}

1;
