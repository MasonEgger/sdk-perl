# ABOUTME: Fixture workflow probing call-site activity option validation (spec
# ABOUTME: R35 / finding A2): each mode calls execute_/start_(local_)activity
# ABOUTME: with bad or valid options and returns the caught exception class (or
# ABOUTME: 'scheduled'/'no-error') so the replay test can assert by class.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run dispatches on its single mode argument. Error-probe modes make the
# offending call inside an eval and return the class of what was raised (or
# 'no-error' when nothing was, the pre-R35 behavior). Valid-probe modes start
# an activity with only known keys and a required timeout, then return
# 'scheduled' WITHOUT awaiting the handle, so the schedule command and the
# workflow completion land in the same activation for the test to inspect.
class WfDef::ActivityOptionProbe :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($mode = 'act_valid') {
        # Classify what a call raises: the exception class, a marker for an
        # unblessed die, or 'no-error' when the call went through.
        my $classify = sub ($call) {
            my $ok = eval { $call->(); 1 };
            return 'no-error' if $ok;
            return Scalar::Util::blessed($@) // 'unblessed';
        };

        if ($mode eq 'act_no_timeout') {
            # Neither start_to_close_timeout nor schedule_to_close_timeout;
            # the OTHER timeouts do not satisfy the rule (Python parity).
            return $classify->(sub {
                Temporalio::Workflow::execute_activity(
                    'SayHello',
                    args                      => ['x'],
                    schedule_to_start_timeout => 30,
                );
            });
        }
        if ($mode eq 'act_unknown_key') {
            return $classify->(sub {
                Temporalio::Workflow::execute_activity(
                    'SayHello',
                    args                   => ['x'],
                    start_to_close_timeout => 60,
                    bogus_option           => 1,
                );
            });
        }
        if ($mode eq 'la_no_timeout') {
            return $classify->(sub {
                Temporalio::Workflow::execute_local_activity(
                    'SayHello',
                    args                      => ['x'],
                    schedule_to_start_timeout => 30,
                );
            });
        }
        if ($mode eq 'la_unknown_key') {
            # heartbeat_timeout is a REGULAR-activity key; local activities do
            # not heartbeat, so here it is an unknown key.
            return $classify->(sub {
                Temporalio::Workflow::execute_local_activity(
                    'SayHello',
                    args                   => ['x'],
                    start_to_close_timeout => 60,
                    heartbeat_timeout      => 10,
                );
            });
        }
        if ($mode eq 'act_valid') {
            # start_to_close_timeout alone satisfies the rule; spread the other
            # known keys to prove strictness does not over-reject.
            Temporalio::Workflow::start_activity(
                'SayHello',
                args                      => ['x'],
                activity_id               => 'probe-1',
                task_queue                => 'probe-q',
                start_to_close_timeout    => 60,
                schedule_to_start_timeout => 30,
                heartbeat_timeout         => 10,
                cancellation_type         => 'try_cancel',
            );
            return 'scheduled';
        }
        if ($mode eq 'la_valid') {
            # schedule_to_close_timeout ALONE satisfies the rule (either of the
            # two qualifies); spread the LA-only known keys too.
            Temporalio::Workflow::start_local_activity(
                'SayHello',
                args                      => ['x'],
                activity_id               => 'probe-la-1',
                schedule_to_close_timeout => 120,
                local_retry_threshold     => 30,
                summary                   => 'probe summary',
                cancellation_type         => 'try_cancel',
            );
            return 'scheduled';
        }
        die "WfDef::ActivityOptionProbe: unknown mode '$mode'";
    }
}

1;
