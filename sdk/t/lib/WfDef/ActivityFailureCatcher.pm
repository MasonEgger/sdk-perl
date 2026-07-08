# ABOUTME: Fixture workflow that catches an activity failure and returns the
# ABOUTME: first application-error detail — drives codec_failure_payloads.t (R7).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run awaits one activity and catches its failure. The runner converts a
# ResolveActivity{failed} through the failure converter, which from_payloads
# the ApplicationFailureInfo details — so a details payload still wearing the
# codec wrapper (NOT decoded at the worker boundary) dies in the converter
# instead of reaching this catch. On the fixed path the body returns the first
# detail value, walking to the Application cause when the failure arrives
# wrapped (e.g. in an activity-failure envelope).
class WfDef::ActivityFailureCatcher :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $result = eval {
            await Temporalio::Workflow::execute_activity(
                'SayHello',
                args                   => ['x'],
                start_to_close_timeout => 60,
            );
        };
        if (my $err = $@) {
            my $app = $err;
            while (Scalar::Util::blessed($app)
                && !$app->isa('Temporalio::Exception::Application')
                && $app->can('cause')
                && defined $app->cause)
            {
                $app = $app->cause;
            }
            return $app->details->[0]
                if Scalar::Util::blessed($app)
                && $app->isa('Temporalio::Exception::Application')
                && $app->details;
            die $err;
        }
        return $result;
    }
}

1;
