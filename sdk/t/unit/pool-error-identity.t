# ABOUTME: Spec R5 (finding L14): error identity must survive the pool fork
# ABOUTME: boundary. Pre-fix, Activity/Pool.pm stringified the child's $@
# ABOUTME: (child frame at the `ok => 0, error => "$@"` site, parent rethrow at
# ABOUTME: `die $out->{error}`) and ActivityDispatcher.pm's _as_exception
# ABOUTME: rewrapped the string as a generic RETRYABLE ApplicationError, so a
# ABOUTME: non-retryable failure retried forever. This is the committed
# ABOUTME: adaptation of probe verify-45/pool-payload/probe_pool_error.pl.
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use IO::Async::Loop ();
use Scalar::Util ();

use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Activity::Invocation ();
use Temporalio::Activity::Pool ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Application ();
use Temporalio::Worker::ActivityRegistry ();

my $loop = IO::Async::Loop->new;

sub await_f ($f) { return $f->get }

# pool->invoke parks on a REAL fork; drive it by running the loop. The
# timeout future loses the race on success, and $f's own failure is what we
# want to inspect, so wait for readiness and read the failure directly.
sub run_to_ready ($f, $timeout = 30) {
    $loop->await(Future->wait_any($f->without_cancel,
        $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $f->is_ready;
    return $f;
}

# One registry with the two failing bodies the spec's acceptance criteria
# name: a non-retryable ApplicationError with type/details/cause, and a plain
# string die.
sub build_registry () {
    return Temporalio::Worker::ActivityRegistry->new(
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'fail_nonretry',
                sync => 1,
                code => sub (@) {
                    Temporalio::Exception::Application->throw(
                        message       => 'boom: do not retry',
                        type          => 'MyFatalError',
                        non_retryable => 1,
                        details       => [ 'detail-1', { code => 7 } ],
                        cause         => Temporalio::Exception::Application->new(
                            message => 'root cause'),
                    );
                },
            ),
            Temporalio::Activity::FunctionDefinition->new(
                name => 'fail_plain',
                sync => 1,
                code => sub (@) { die "kaboom, plain die\n" },
            ),
        ],
    );
}

sub build_pool () {
    return Temporalio::Activity::Pool->new(
        loop        => $loop,
        max_workers => 1,
        registry    => build_registry(),
    );
}

sub invocation_for ($type) {
    return Temporalio::Activity::Invocation->new(
        activity_type => $type,
        args          => [],
        info          => { task_token => "tok-$type" },
        task_token    => "tok-$type",
    );
}

# ---------------------------------------------------------------------------
# Spec R5 acceptance 1, pool level: a non-retryable ApplicationError thrown in
# the forked child reaches the parent as a failure with the ORIGINAL class,
# type, non_retryable, details, and cause chain. Pre-fix the parent saw only
# the stringified $@ (the whole identity was flattened to a message).
# ---------------------------------------------------------------------------
T2->subtest('non-retryable ApplicationError identity survives the fork' => sub {
    my $pool = build_pool();
    my $f    = run_to_ready($pool->invoke(invocation_for('fail_nonretry')));

    T2->ok($f->is_failed, 'invoke fails');
    my ($error) = $f->failure;

    T2->ok(Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Application'),
        'parent-side error is a blessed ApplicationError')
        or T2->diag("got: $error");
    return if !Scalar::Util::blessed($error);    # rest needs the object

    T2->is($error->message, 'boom: do not retry', 'message intact');
    T2->is($error->type, 'MyFatalError', 'original error type preserved');
    T2->ok($error->non_retryable, 'non_retryable preserved (finding L14)');
    T2->is($error->details, [ 'detail-1', { code => 7 } ],
        'details preserved across the fork');
    T2->ok(defined $error->cause
            && $error->cause->isa('Temporalio::Exception::Application'),
        'cause chain preserved');
    T2->is($error->cause->message, 'root cause', 'cause message intact');

    $pool->close;
});

# ---------------------------------------------------------------------------
# Spec R5 acceptance 2, pool level: a plain die maps to a RETRYABLE
# ApplicationError with the message intact (the sdk-python parity shape: a
# non-Temporal error wraps as a retryable ApplicationFailure; Perl's failure
# converter uses the sentinel type Temporalio::Exception::Plain, T-fail-4).
# ---------------------------------------------------------------------------
T2->subtest('plain die maps to a retryable failure with message intact' => sub {
    my $pool = build_pool();
    my $f    = run_to_ready($pool->invoke(invocation_for('fail_plain')));

    T2->ok($f->is_failed, 'invoke fails');
    my ($error) = $f->failure;

    T2->ok(Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Application'),
        'plain die arrives as a blessed ApplicationError')
        or T2->diag("got: $error");
    return if !Scalar::Util::blessed($error);    # rest needs the object

    T2->is($error->message, 'kaboom, plain die', 'die message intact');
    T2->ok(!$error->non_retryable, 'plain die stays retryable');

    $pool->close;
});

# ---------------------------------------------------------------------------
# End to end through the REAL dispatcher: the completion core receives must
# carry ApplicationFailureInfo with the original non_retryable/type. Pre-fix,
# _as_exception (ActivityDispatcher.pm) saw the pool's stringified error and
# wrapped it as a generic retryable ApplicationError, so core's retry loop
# never stopped ("retries forever", finding L14).
# ---------------------------------------------------------------------------
T2->subtest('dispatcher completion carries the original failure semantics' => sub {
    require Temporalio::Worker::ActivityDispatcher;

    my $dc = Temporalio::Converter::Data->new;

    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => build_registry(),
        data_converter => $dc,
        task_queue     => 'demo',
        loop           => $loop,
        pool           => build_pool(),
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
    );

    my $ActivityTask = Temporalio::Core::Proto::resolve(
        'coresdk.activity_task.ActivityTask');
    my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
    my $Completion = Temporalio::Core::Proto::resolve(
        'coresdk.ActivityTaskCompletion');

    my sub start_bytes ($token, $type) {
        my $start = $Start->new({
            workflow_namespace => 'default',
            activity_id        => 'a-1',
            activity_type      => $type,
            input              => [],
            attempt            => 1,
        });
        return $ActivityTask->new(
            { task_token => $token, start => $start })->encode;
    }

    # Non-retryable ApplicationError: the completion's failure info must say
    # non_retryable with the original type.
    run_to_ready($dispatcher->dispatch_task(
        start_bytes('tok-nr', 'fail_nonretry')));
    T2->is(scalar(@completions), 1, 'non-retryable activity completed');
    my $comp = $Completion->decode($completions[0]);
    T2->is($comp->result->which_status, 'failed', 'completion status is failed');
    my $failure = $comp->result->failed->failure;
    T2->is($failure->message, 'boom: do not retry', 'failure message intact');
    my $info = $failure->application_failure_info;
    T2->ok(defined $info, 'failure carries ApplicationFailureInfo');
    return if !defined $info;    # rest needs the info variant
    T2->ok($info->non_retryable,
        'completion is NON-retryable (core stops retrying)');
    T2->is($info->type, 'MyFatalError', 'completion carries the original type');
    T2->ok(defined $failure->cause, 'completion carries the cause chain');

    # Plain die: retryable, message intact.
    @completions = ();
    run_to_ready($dispatcher->dispatch_task(
        start_bytes('tok-pl', 'fail_plain')));
    T2->is(scalar(@completions), 1, 'plain-die activity completed');
    my $comp_pl = $Completion->decode($completions[0]);
    T2->is($comp_pl->result->which_status, 'failed', 'plain die fails');
    my $failure_pl = $comp_pl->result->failed->failure;
    T2->is($failure_pl->message, 'kaboom, plain die',
        'plain-die message intact in the completion');
    my $info_pl = $failure_pl->application_failure_info;
    T2->ok(defined $info_pl && !$info_pl->non_retryable,
        'plain die stays retryable in the completion');
});

T2->done_testing;
