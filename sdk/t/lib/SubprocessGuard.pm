# ABOUTME: A hard-timeout subprocess guard for live integration repros whose
# ABOUTME: failure mode is a HANG (B3 #5/#8, B4-B6). Forks a child that runs the
# ABOUTME: whole worker+cancel scenario and exits 0 only on a verified-clean
# ABOUTME: outcome; the parent reaps it under a hard timeout and KILLS the whole
# ABOUTME: process group on overrun, so a hung scenario can never wedge `prove`.
package SubprocessGuard;
use v5.38;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(run_guarded);

use POSIX ();
use Time::HiRes ();

# run_guarded($child_code, timeout => N) -> ( ok => 0|1, reason => $string )
#
# Forks. The child:
#   * becomes its own session/process-group leader (POSIX::setsid) so the parent
#     can kill the entire subtree (including the dev-server CLI that sdk-core
#     spawns) with a single process-group signal on a hard-timeout overrun;
#   * runs $child_code in an eval. A TRUE return -> exit 0 (the scenario verified
#     its expected outcome). A false return or a die -> exit 1 (with the error on
#     STDERR as a diagnostic). NOTHING the child does touches Test2 — the PARENT
#     owns the TAP stream — and the child leaves via POSIX::_exit so no END /
#     done_testing handler fires in the forked copy.
#
# The parent polls waitpid(WNOHANG) up to `timeout` seconds. If the child has
# not exited by the deadline the scenario hung (the documented #8 ~183s wedge);
# the parent TERM-then-KILLs the child's process group, reaps it, and reports a
# clean failure rather than blocking the suite.
#
# IMPORTANT: the caller MUST NOT create a Temporalio::Runtime (or any threaded
# FFI state) in the parent before calling this — fork() in a process that has
# already started sdk-core's Tokio threads is unsafe. Create the runtime INSIDE
# $child_code (it runs only in the forked child).
sub run_guarded ($child_code, %opts) {
    my $timeout = $opts{timeout} // 30;

    my $pid = fork;
    die "SubprocessGuard: fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        # --- child ---------------------------------------------------------
        POSIX::setsid();   # new session+group; parent kills -$pid to get the CLI
        my $ok = do {
            local $@;
            my $r = eval { $child_code->() ? 1 : 0 };
            if ($@) {
                print STDERR "SubprocessGuard child died: $@\n";
                0;
            }
            elsif (!$r) {
                print STDERR "SubprocessGuard child returned false\n";
                0;
            }
            else { 1 }
        };
        POSIX::_exit($ok ? 0 : 1);
    }

    # --- parent ------------------------------------------------------------
    my $deadline = Time::HiRes::time() + $timeout;
    my $reaped   = 0;
    while (Time::HiRes::time() < $deadline) {
        my $w = waitpid($pid, POSIX::WNOHANG());
        if ($w == $pid) { $reaped = 1; last }
        Time::HiRes::sleep(0.2);
    }

    if (!$reaped) {
        # Hard timeout: the scenario hung. Kill the whole process group so the
        # forked child AND the dev-server CLI it spawned are reaped, then block
        # on a final waitpid to avoid a zombie.
        kill 'TERM', -$pid;
        Time::HiRes::sleep(0.5);
        kill 'KILL', -$pid;
        waitpid($pid, 0);
        return (ok => 0, reason => "child did not exit within ${timeout}s (scenario hung)");
    }

    my $status = $?;
    return (ok => 1, reason => 'child exited 0 (scenario verified)') if $status == 0;

    my $sig  = $status & 0x7f;
    my $code = $status >> 8;
    return (ok => 0,
        reason => "child exited non-zero (exit code $code, signal $sig)");
}

1;
