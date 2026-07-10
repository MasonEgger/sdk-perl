# ABOUTME: Integration fixture (P7.2): schedules the CaptureAndCompleteAsync
# ABOUTME: activity, which declares it will complete out of band, and returns
# ABOUTME: the activity result the test later supplies through an
# ABOUTME: AsyncActivityHandle.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::AsyncActivityWorkflow :isa(Temporalio::Workflow::Definition) {
    async method run :Run('AsyncActivityWorkflow') () {
        my $result = await Temporalio::Workflow::execute_activity(
            'CaptureAndCompleteAsync',
            args                   => [],
            start_to_close_timeout => 120,
        );
        return $result;
    }
}

1;
