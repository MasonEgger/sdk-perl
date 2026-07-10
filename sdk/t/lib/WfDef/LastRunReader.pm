# ABOUTME: Fixture workflow that snapshots the last-run carry-over accessors
# ABOUTME: (has_/get_last_completion_result, get_last_failure; spec R88) —
# ABOUTME: drives last_completion_result.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run reads all three carry-over accessors and returns a snapshot as the
# workflow result so the test can decode it off the completion command. The
# failure (a typed Temporalio::Exception::*) cannot ride a JSON payload, so
# the snapshot carries its class, message, and type instead. Uses the
# class-method call shape for has_last_completion_result (the plan's asserted
# form) and the package-function shape for the getters — both must work.
class WfDef::LastRunReader :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $has     = Temporalio::Workflow->has_last_completion_result ? 1 : 0;
        my $result  = Temporalio::Workflow::get_last_completion_result();
        my $failure = Temporalio::Workflow::get_last_failure();
        return {
            has     => $has,
            result  => $result,
            failure => (defined $failure ? {
                class   => ref($failure),
                message => $failure->message,
                type    => ($failure->can('type') ? $failure->type : undef),
            } : undef),
        };
    }
}

1;
