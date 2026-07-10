# ABOUTME: Unit tests for worker-shutdown detection inside activities (spec
# ABOUTME: R84, parity activity/conversion finding 4): the dispatcher's
# ABOUTME: notify_shutdown flips $ctx->is_worker_shutdown and resolves the
# ABOUTME: wait_for_worker_shutdown future, distinct from a plain cancel
# ABOUTME: (Python activity.py:400-438, worker/_activity.py:185-187).
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;
use IO::Async::Loop ();

use Temporalio::Activity ();
use Temporalio::Activity::Context ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Cancellation ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Cancelled ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::ActivityRegistry ();

my $loop = IO::Async::Loop->new;

# This class block sits BEFORE any signatured sub: on perl 5.38.2 a
# `field $x :param;` fails to parse ("Subroutine attributes must come before
# the signature") when the most recently compiled named sub had a signature.
class FakeClient {
    field $data_converter :param;
    method data_converter { $data_converter }
    method namespace      { 'default' }
    method identity       { 'pid@host' }
}

# These Futures resolve synchronously (in-memory converters, injected
# completers, bodies that park only on the shutdown event / cancellation we
# fire ourselves), so ->get drives them without running the loop — the
# activity_dispatch.t pattern.
sub await_f ($f) { return $f->get }

my $ActivityTask = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityTask');
my $Start = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.Start');
my $Cancel = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.Cancel');
my $Details = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityCancellationDetails');
my $WorkflowExecution = Temporalio::Core::Proto::resolve(
    'temporal.api.common.v1.WorkflowExecution');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.ActivityTaskCompletion');

sub start_task_bytes ($token, $type) {
    my $start = $Start->new({
        workflow_namespace => 'default',
        workflow_type      => 'GreetWorkflow',
        workflow_execution => $WorkflowExecution->new({
            workflow_id => 'wf-1', run_id => 'run-1' }),
        activity_id   => 'act-1',
        activity_type => $type,
        input         => [],
        attempt       => 1,
    });
    return $ActivityTask->new({ task_token => $token, start => $start })->encode;
}

# An ORDINARY cancel (ActivityCancelReason CANCELLED=1, is_cancelled flag) —
# NOT a worker shutdown; R84's whole point is that the two are told apart.
sub plain_cancel_bytes ($token) {
    return $ActivityTask->new({
        task_token => $token,
        cancel     => $Cancel->new({
            reason  => 1,
            details => $Details->new({ is_cancelled => 1 }),
        }),
    })->encode;
}

sub build_dispatcher (%args) {
    my $dc          = Temporalio::Converter::Data->new;
    my $registry    = Temporalio::Worker::ActivityRegistry->new(
        activities => $args{activities});
    my $completions = [];
    my $dispatcher  = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        client         => FakeClient->new(data_converter => $dc),
        loop           => $loop,
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
        heartbeat_recorder => sub ($bytes) { return undef },
    );
    return ($dispatcher, $completions);
}

T2->subtest('worker shutdown flips is_worker_shutdown + resolves the future' => sub {
    my %seen;
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'shutdown_waiter',
        code => async sub (@) {
            my $ctx = Temporalio::Activity::context();
            $seen{before} = $ctx->is_worker_shutdown;
            # Await through the PACKAGE function so the functional surface
            # (Python's module-level wait_for_worker_shutdown) is covered too.
            await Temporalio::Activity::wait_for_worker_shutdown();
            $seen{after}     = $ctx->is_worker_shutdown;
            $seen{pkg_after} = Temporalio::Activity::is_worker_shutdown();
            return 'saw-shutdown';
        },
    );
    my ($dispatcher, $completions) =
        build_dispatcher(activities => [$fn]);

    my $run_f = $dispatcher->dispatch_task(
        start_task_bytes('tok-shutdown', 'shutdown_waiter'));
    T2->ok(!$run_f->is_ready, 'body is parked on the shutdown future');

    $dispatcher->notify_shutdown;
    await_f($run_f);

    T2->ok(!$seen{before}, 'is_worker_shutdown false before shutdown begins');
    T2->ok($seen{after},   'is_worker_shutdown true once shutdown begins');
    T2->ok($seen{pkg_after},
        'Temporalio::Activity::is_worker_shutdown() agrees');

    my $comp = $Completion->decode($completions->[0]);
    T2->is($comp->result->which_status, 'completed',
        'the activity woke and completed normally');
});

T2->subtest('a plain cancel is NOT a worker shutdown' => sub {
    my %seen;
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'cancel_waiter',
        code => async sub (@) {
            my $ctx        = Temporalio::Activity::context();
            my $shutdown_f = $ctx->wait_for_worker_shutdown;
            await $ctx->cancellation->cancelled;
            $seen{flag}             = $ctx->is_worker_shutdown;
            $seen{shutdown_pending} = $shutdown_f->is_ready ? 0 : 1;
            Temporalio::Exception::Cancelled->throw(message => 'cancelled');
        },
    );
    my ($dispatcher, $completions) =
        build_dispatcher(activities => [$fn]);

    my $run_f = $dispatcher->dispatch_task(
        start_task_bytes('tok-cancel', 'cancel_waiter'));
    await_f($dispatcher->dispatch_task(plain_cancel_bytes('tok-cancel')));
    await_f($run_f);

    T2->ok(!$seen{flag},
        'is_worker_shutdown stays false through an ordinary cancel');
    T2->ok($seen{shutdown_pending},
        'the shutdown future stays pending through an ordinary cancel');

    my $comp = $Completion->decode($completions->[0]);
    T2->is($comp->result->which_status, 'cancelled',
        'the activity still completes cancelled');
});

T2->subtest('an activity started after shutdown-begin sees it immediately' => sub {
    my %seen;
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'late_starter',
        code => async sub (@) {
            my $ctx = Temporalio::Activity::context();
            $seen{flag} = $ctx->is_worker_shutdown;
            # Already-set event: the await must resolve without parking.
            await $ctx->wait_for_worker_shutdown;
            return 'done';
        },
    );
    my ($dispatcher, $completions) =
        build_dispatcher(activities => [$fn]);

    $dispatcher->notify_shutdown;
    await_f($dispatcher->dispatch_task(
        start_task_bytes('tok-late', 'late_starter')));

    T2->ok($seen{flag}, 'is_worker_shutdown already true at body entry');
    my $comp = $Completion->decode($completions->[0]);
    T2->is($comp->result->which_status, 'completed',
        'the already-resolved future did not park the body');
});

T2->subtest('directly-constructed context (no event) degrades safely' => sub {
    # The fork-pool child builds its own context with no dispatcher event
    # (the event does not cross the fork — the R76 holder deviation); the
    # accessors must degrade, not die.
    my $ctx = Temporalio::Activity::Context->new(
        info               => { task_token => 't' },
        cancellation       => Temporalio::Cancellation->new,
        data_converter     => Temporalio::Converter::Data->new,
        heartbeat_recorder => sub ($bytes) { return undef },
    );
    T2->ok(!$ctx->is_worker_shutdown,
        'is_worker_shutdown false without a dispatcher event');
    my $f = $ctx->wait_for_worker_shutdown;
    T2->ok(defined $f && !$f->is_ready,
        'wait_for_worker_shutdown returns a pending (never-resolving) future');
});

T2->done_testing;
