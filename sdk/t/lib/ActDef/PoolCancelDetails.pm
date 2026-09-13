# ABOUTME: Fixture activity class for step I7 direction A (spec R76 parity for
# ABOUTME: fork-pool sync activities): polls ctx->cancellation->is_cancelled
# ABOUTME: until a cancel lands, then reports the observed cancellation_details
# ABOUTME: and is_worker_shutdown so the parent-process test can assert on them.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Time::HiRes ();
use Temporalio::Activity ();
use Temporalio::Activity::Definition;

class ActDef::PoolCancelDetails :isa(Temporalio::Activity::Definition) {
    method run :Defn('PoolCancelDetails', 'sync=1') ($started_file, $deadline_secs = 10) {
        my $ctx      = Temporalio::Activity::context();
        open my $fh, '>', $started_file
            or die "cannot create $started_file: $!";
        close $fh;
        my $deadline = Time::HiRes::time() + $deadline_secs;
        until ($ctx->cancellation->is_cancelled) {
            return { timed_out_waiting => 1 }
                if Time::HiRes::time() > $deadline;
            Time::HiRes::sleep(0.02);
        }
        my $details = $ctx->cancellation_details;
        return {
            reason              => defined $details ? $details->reason : undef,
            not_found           => defined $details ? $details->not_found        : 0,
            cancel_requested    => defined $details ? $details->cancel_requested : 0,
            paused              => defined $details ? $details->paused           : 0,
            reset               => defined $details ? $details->reset            : 0,
            timed_out           => defined $details ? $details->timed_out        : 0,
            worker_shutdown     => defined $details ? $details->worker_shutdown  : 0,
            is_worker_shutdown  => $ctx->is_worker_shutdown ? 1 : 0,
        };
    }
}

1;
