# ABOUTME: hello-world example — the GreetingWorkflow. A class-based workflow
# ABOUTME: definition (spec section 10.1) whose :Run calls the SayHello activity
# ABOUTME: and returns its result.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The workflow orchestrates: it schedules the SayHello activity, awaits the
# greeting, and returns it. Workflow code must be deterministic — it never
# performs I/O directly; it drives activities for that. The await suspends the
# workflow until the activity result comes back (durably, across worker
# restarts).
class HelloWorld::GreetingWorkflow :isa(Temporalio::Workflow::Definition) {
    async method run :Run('GreetingWorkflow') ($name = 'World') {
        my $greeting = await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => [$name],
            start_to_close_timeout => 30,
        );
        return $greeting;
    }
}

1;
