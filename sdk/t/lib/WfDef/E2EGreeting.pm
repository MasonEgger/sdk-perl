# ABOUTME: End-to-end fixture workflow (P3.9): calls the SayHello activity and
# ABOUTME: returns its greeting — exercises the full client+worker round trip.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Greeting workflow: schedule SayHello($name), await its result, return it
# verbatim ("Hello, $name!"). The explicit :Run name pins the workflow type so
# the client starts it by a stable string.
class WfDef::E2EGreeting :isa(Temporalio::Workflow::Definition) {
    async method run :Run('E2EGreeting') ($name = 'World') {
        my $greeting = await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => [$name],
            start_to_close_timeout => 30,
        );
        return $greeting;
    }
}

1;
