# ABOUTME: Unit tests for the best-effort workflow determinism guard (spec §29.4,
# ABOUTME: P10.8, T-det-1..7): time/entropy CORE::GLOBAL:: overrides gated on
# ABOUTME: $Runner::CURRENT, the dynamically-scoped Unsafe escape hatch, SDK
# ABOUTME: primitive self-exemption, idempotent install, and the narrowed
# ABOUTME: best-effort boundary (CORE::-qualified + IO builtins NOT trapped).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
no warnings 'experimental::class';

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow ();
use Temporalio::Workflow::Unsafe ();
use Temporalio::Workflow::DeterminismGuard ();
use Temporalio::Converter::Payload ();

# The guard is process-global; install it once for the whole test run. It is a
# no-op outside workflow context, so installing it here does not perturb the
# test harness itself.
Temporalio::Workflow::DeterminismGuard::install();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# Drive a one-activation run of $wf_class and return the decoded completion.
sub run_once ($wf_class, %opts) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => $wf_class,
        %opts,
    );
    return $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => { workflow_type => $wf_class } } ],
    }));
}

# ---------------------------------------------------------------------------
# T-det-1: a CORE builtin (time, rand) called inside a workflow body is trapped
# as Nondeterminism. By default that routes to a workflow-TASK failure (the
# server retries the task), exactly like an unknown-seq non-determinism.
# ---------------------------------------------------------------------------
T2->subtest('time/rand in a workflow body throw Nondeterminism (T-det-1)' => sub {
    for my $wf (qw(WfDef::IllegalTime WfDef::IllegalRand)) {
        my $completion = run_once($wf);
        T2->is($completion->which_status, 'failed',
            "$wf: trapped builtin -> task failure");
        T2->like($completion->failed->failure->message, qr/non-?determin/i,
            "$wf: failure message names non-determinism");
    }
});

# ---------------------------------------------------------------------------
# T-det-1 (negative): the SAME builtins called OUTSIDE workflow context (no
# $Runner::CURRENT) return real OS values and never throw. The guard is gated
# strictly on `defined $Runner::CURRENT`.
# ---------------------------------------------------------------------------
T2->subtest('builtins outside workflow context return real values (T-det-1)' => sub {
    T2->ok(!defined $Temporalio::Workflow::Runner::CURRENT,
        'no active runner outside a workflow body');
    my $t = time;
    T2->ok($t > 1_700_000_000, 'time returns a real epoch outside workflow');
    my $r = rand;
    T2->ok($r >= 0 && $r < 1, 'rand returns a real value outside workflow');
    my @lt = localtime;
    T2->is(scalar @lt, 9, 'localtime returns its 9-element list outside workflow');
    my $ok = eval { sleep 0; 1 };
    T2->ok($ok, 'sleep 0 runs outside workflow');
});

# ---------------------------------------------------------------------------
# T-det-2: Unsafe::illegal_call_tracing_disabled suppresses the guard for the
# block (the trapped call returns the OS value) and RESTORES guarding after.
# ---------------------------------------------------------------------------
T2->subtest('illegal_call_tracing_disabled suppresses + restores (T-det-2)' => sub {
    # The default (leak=0) fixture calls `time` ONLY inside the escape block and
    # returns. The escape returns a real epoch and the body completes - no task
    # failure. After the block the guard is restored (proven by T-det-3 below,
    # which leaks a bare call past the escape and gets trapped).
    my $completion = run_once('WfDef::UnsafeEscape');
    T2->isnt($completion->which_status, 'failed',
        'a guarded builtin under the escape does NOT fail the task');
    my $success = $completion->successful;
    T2->ok(defined $success, 'escape-only body produced a successful completion');
});

# ---------------------------------------------------------------------------
# T-det-3: suppression is dynamically scoped and survives an await - but does
# NOT leak past the block. The UnsafeEscape fixture (with leak=1) calls `time`
# inside the escape (ok), awaits a timer, then calls `time` OUTSIDE the escape
# after resuming -> that bare call must throw.
# ---------------------------------------------------------------------------
T2->subtest('suppression does not leak across the await (T-det-3)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::UnsafeEscape',
    );
    # leak=1 argument.
    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'WfDef::UnsafeEscape',
            arguments     => [ { metadata => { encoding => 'json/plain' }, data => '1' } ],
        } } ],
    }));
    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));
    T2->is($completion->which_status, 'failed',
        'the post-await bare `time` outside the escape is trapped');
    T2->like($completion->failed->failure->message, qr/non-?determin/i,
        'leaked-call failure names non-determinism');
});

# ---------------------------------------------------------------------------
# T-det-4: the SDK's own deterministic primitives (Workflow::time / now /
# random) never throw, even with the guard installed and $Runner::CURRENT set.
#
# now is the load-bearing exemption (bug #4, B10 C-COND-TIMEOUT): it builds a
# DateTime via DateTime->from_epoch, which internally calls the `gmtime` builtin
# the guard traps. Without the guard-suppression hatch in Workflow::now, SafeNow
# (which now calls Workflow::now->epoch) task-fails under the installed guard,
# the exact wedge the updatable-timer sample hit live, where every loop iteration
# calls now. Asserting now->epoch equals the activation timestamp proves the
# primitive both runs and returns the deterministic value, not a real wall clock.
# ---------------------------------------------------------------------------
T2->subtest('SDK now/time/random never throw under the guard (T-det-4)' => sub {
    my $completion = run_once('WfDef::SafeNow');
    T2->isnt($completion->which_status, 'failed',
        'SafeNow completes - SDK primitives (incl. now) self-exempt');
    my $success = $completion->successful;
    T2->ok(defined $success, 'SafeNow produced a successful completion');

    # The body returned { t, now, r }; now must equal the activation epoch (100s),
    # confirming Workflow::now ran under the guard and read the deterministic time.
    my @cmds = $success ? ($success->commands // [])->@* : ();
    my ($complete) =
        grep { $_->which_variant eq 'complete_workflow_execution' } @cmds;
    T2->ok(defined $complete, 'SafeNow emitted a CompleteWorkflowExecution');
    my $result = Temporalio::Converter::Payload->default->from_payload(
        $complete->complete_workflow_execution->result);
    T2->is($result->{now}, 100,
        'Workflow::now ran under the guard and returned the activation epoch (#4)');
});

# ---------------------------------------------------------------------------
# T-det-5: Time::HiRes::time inside a workflow body is also trapped (symbol-table
# override, not a CORE::GLOBAL:: builtin).
# ---------------------------------------------------------------------------
T2->subtest('Time::HiRes::time in a workflow body throws (T-det-5)' => sub {
    my $completion = run_once('WfDef::IllegalHiRes');
    T2->is($completion->which_status, 'failed',
        'Time::HiRes::time trapped -> task failure');
    T2->like($completion->failed->failure->message, qr/non-?determin/i,
        'Time::HiRes failure names non-determinism');

    # Outside workflow context Time::HiRes::time returns a real value.
    require Time::HiRes;
    T2->ok(!defined $Temporalio::Workflow::Runner::CURRENT, 'no runner active');
    my $hr = Time::HiRes::time();
    T2->ok($hr > 1_700_000_000, 'Time::HiRes::time real outside workflow');
});

# ---------------------------------------------------------------------------
# T-det-6: install() is idempotent (a second call does not double-wrap or break
# the override) and third-party code outside workflow context is unaffected.
# ---------------------------------------------------------------------------
T2->subtest('idempotent double-install; third-party unaffected (T-det-6)' => sub {
    # Second install is a no-op.
    my $ok = eval { Temporalio::Workflow::DeterminismGuard::install(); 1 };
    T2->ok($ok, 'second install() is a harmless no-op');
    T2->ok(Temporalio::Workflow::DeterminismGuard::is_installed(),
        'guard reports installed');

    # Third-party-style call outside a workflow still works after double-install.
    my $t1 = time;
    my $t2 = time;
    T2->ok($t1 > 1_700_000_000 && $t2 >= $t1,
        'time still monotonic-ish + real outside workflow after double install');

    # And a workflow body is still trapped (the override survived re-install).
    my $completion = run_once('WfDef::IllegalTime');
    T2->is($completion->which_status, 'failed',
        'override still active after idempotent re-install');
});

# ---------------------------------------------------------------------------
# T-det-7: the NARROWED best-effort boundary (spec §29.4 M2). CORE::-qualified
# `CORE::time` is NOT trapped (we cannot override an explicitly-qualified call),
# and the IO/process builtins (system/open/fork) are NOT overridden by default
# (they risk trapping IO::Async + the fork pool). This pins the documented gap.
# ---------------------------------------------------------------------------
T2->subtest('CORE::time and system/open NOT trapped by default (T-det-7)' => sub {
    my $completion = run_once('WfDef::CoreQualified');
    T2->isnt($completion->which_status, 'failed',
        'CORE::time inside a workflow is NOT trapped (best-effort gap)');

    # system/open are not overridden: a workflow body running `defined &CORE::GLOBAL::system`
    # should be false (we never install those overrides).
    T2->ok(!defined &CORE::GLOBAL::system,
        'system is not overridden by the default guard');
    T2->ok(!defined &CORE::GLOBAL::open,
        'open is not overridden by the default guard');
    T2->ok(!defined &CORE::GLOBAL::fork,
        'fork is not overridden by the default guard');
});

T2->done_testing;
