# ABOUTME: Spec R62 (finding L32): the original error cause must survive two
# ABOUTME: hand-off points. (1) A pool child's activity-module require failure
# ABOUTME: was swallowed (Activity/Pool.pm init_code `eval { require ...; 1 }`
# ABOUTME: with no error capture), so a broken module surfaced later as a
# ABOUTME: masking symptom instead of the real load error. (2) Worker::run's
# ABOUTME: finalize die (Worker.pm _finalize_and_free rethrow, awaited
# ABOUTME: unprotected after the poll-loop error was saved) REPLACED that saved
# ABOUTME: error, so the primary failure vanished.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Temp ();
use Future ();
use IO::Async::Loop ();
use Scalar::Util ();

use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Activity::Invocation ();
use Temporalio::Activity::Pool ();
use Temporalio::Exception::Bridge ();
use Temporalio::Exception::Runtime ();
use Temporalio::Worker ();
use Temporalio::Worker::ActivityRegistry ();

my $loop = IO::Async::Loop->new;

# pool->invoke parks on a REAL fork; drive it by running the loop (the
# pool-error-identity.t pattern). Wait for readiness, then inspect.
sub run_to_ready ($f, $timeout = 30) {
    $loop->await(Future->wait_any($f->without_cancel,
        $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $f->is_ready;
    return $f;
}

# ---------------------------------------------------------------------------
# Shape 1 (spec R62 acceptance): a pool child's `require` failure surfaces
# with the ORIGINAL message, module name included. The registry body itself
# is healthy (its code ref is fork-copied), so pre-fix the swallow made the
# invoke SUCCEED and the load error vanished without trace.
# ---------------------------------------------------------------------------
T2->subtest('pool-child require failure surfaces with the module name' => sub {
    # A module that fails to load with a distinctive cause message.
    my $dir = File::Temp->newdir('temporalio-r62-XXXXXX', TMPDIR => 1);
    my $mod_path = "$dir/R62BrokenModule.pm";
    open my $fh, '>', $mod_path or die "cannot write $mod_path: $!";
    print {$fh} "die \"R62 original require cause: missing dependency\\n\";\n";
    close $fh;

    # The child inherits \@INC across the fork, so the parent-side unshift
    # makes the broken module findable in the child's require.
    unshift @INC, "$dir";

    my $pool = Temporalio::Activity::Pool->new(
        loop             => $loop,
        max_workers      => 1,
        activity_modules => ['R62BrokenModule'],
        registry         => Temporalio::Worker::ActivityRegistry->new(
            activities => [
                Temporalio::Activity::FunctionDefinition->new(
                    name => 'echo',
                    sync => 1,
                    code => sub (@) { return 'ok' },
                ),
            ],
        ),
    );

    my $f = run_to_ready($pool->invoke(
        Temporalio::Activity::Invocation->new(
            activity_type => 'echo',
            args          => [],
            info          => { task_token => 'tok-r62' },
            task_token    => 'tok-r62',
        )));

    T2->ok($f->is_failed,
        'invoke fails when a declared activity module cannot load '
        . '(pre-R62 the require failure was swallowed and this succeeded)');
    if ($f->is_failed) {
        my ($error) = $f->failure;
        my $text = "$error";
        T2->ok(index($text, 'R62BrokenModule') >= 0,
            'surfaced error names the module') or T2->diag("got: $text");
        T2->ok(index($text, 'R62 original require cause: missing dependency') >= 0,
            'surfaced error carries the ORIGINAL require message')
            or T2->diag("got: $text");
    }

    $pool->close;
    shift @INC;
});

# ---------------------------------------------------------------------------
# Shape 2 (spec R62 acceptance): a finalize die attaches to, never replaces,
# the saved error. The preserve-cause hand-off is the package sub
# Temporalio::Worker::_attach_secondary_error, wired at run()'s single
# finalize unwind point (the worker_shutdown_tolerance.t precedent: unit-test
# the classifier/helper the run path calls).
# ---------------------------------------------------------------------------
T2->subtest('finalize failure attaches to (not replaces) the saved error' => sub {
    my $attach = Temporalio::Worker->can('_attach_secondary_error');
    T2->ok($attach,
        '_attach_secondary_error is defined (the R62 preserve-cause hand-off)');
    return unless $attach;

    # Plain-string primary: the combined error still STARTS with the primary
    # message and carries the finalize failure after it.
    my $combined = $attach->("poll loop failed: boom\n", "finalize exploded\n");
    T2->ok(index("$combined", 'poll loop failed: boom') == 0,
        'string primary survives first (not replaced)')
        or T2->diag("got: $combined");
    T2->ok(index("$combined", 'finalize exploded') >= 0,
        'finalize failure attached to the string primary')
        or T2->diag("got: $combined");

    # Blessed primary: the SAME exception object comes back (class identity
    # preserved for isa-checking callers), its message is untouched, and the
    # finalize failure rides along as a secondary error visible in the
    # stringification.
    my $primary   = Temporalio::Exception::Runtime->new(
        message => 'poll loop failed');
    my $secondary = Temporalio::Exception::Bridge->new(
        message => 'finalize exploded');
    my $result = $attach->($primary, $secondary);
    T2->is(Scalar::Util::refaddr($result), Scalar::Util::refaddr($primary),
        'blessed primary is returned as the SAME object');
    T2->ok($result->isa('Temporalio::Exception::Runtime'),
        'primary class identity preserved');
    T2->is($result->message, 'poll loop failed',
        'primary message untouched (attach, not replace)');
    T2->ok(index("$result", 'poll loop failed') >= 0
            && index("$result", 'finalize exploded') >= 0,
        'stringification carries BOTH the primary and the attached failure')
        or T2->diag("got: $result");
    my $attached = $result->secondary_errors;
    T2->is(scalar(@$attached), 1, 'one secondary error recorded');
    T2->is(Scalar::Util::refaddr($attached->[0]),
        Scalar::Util::refaddr($secondary),
        'the recorded secondary is the finalize failure itself');

    # Degenerate arms: no saved error means the finalize failure IS the
    # primary; no finalize failure returns the saved error unchanged.
    my $only_secondary = $attach->(undef, "finalize exploded\n");
    T2->is("$only_secondary", "finalize exploded\n",
        'undef primary passes the secondary through');
    my $only_primary = $attach->($primary, undef);
    T2->is(Scalar::Util::refaddr($only_primary),
        Scalar::Util::refaddr($primary),
        'undef secondary passes the primary through');
});

T2->done_testing;
