# ABOUTME: Unit tests for activity cancellation details + reason (spec R76,
# ABOUTME: parity worker finding 2 / activity+conversion finding 3): the
# ABOUTME: dispatcher captures the Cancel job's reason + ActivityCancellationDetails
# ABOUTME: and the context exposes them, Python activity.py:169-191,315-317.
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
# completers, bodies that park only on the cancellation we fire ourselves),
# so ->get drives them without running the loop — the activity_dispatch.t
# pattern.
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

sub start_task_bytes ($dc, $token, $type) {
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

# A Cancel variant carrying a reason (ActivityCancelReason number, vendored
# activity_task.proto:87-100 — NOT_FOUND=0 CANCELLED=1 TIMED_OUT=2
# WORKER_SHUTDOWN=3 PAUSED=4 RESET=5) and ActivityCancellationDetails flags.
sub cancel_task_bytes ($token, $reason, %flags) {
    return $ActivityTask->new({
        task_token => $token,
        cancel     => $Cancel->new({
            reason  => $reason,
            details => $Details->new({ %flags }),
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
    return ($dispatcher, $dc, $completions);
}

# Drive one park-on-cancel activity through the dispatcher, deliver the given
# cancel task, and return what the body observed: the pre-cancel value of
# cancellation_details, the post-cancel details object, and the identity check
# against the Temporalio::Activity package function.
sub run_cancelled_activity ($token, $cancel_bytes) {
    my %seen;
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'waiter',
        code => async sub (@) {
            my $ctx = Temporalio::Activity::context();
            $seen{before} = $ctx->cancellation_details;
            await $ctx->cancellation->cancelled;
            $seen{after}    = $ctx->cancellation_details;
            $seen{pkg_same} = Temporalio::Activity::cancellation_details()
                == $ctx->cancellation_details ? 1 : 0;
            Temporalio::Exception::Cancelled->throw(message => 'cancelled');
        },
    );
    my ($dispatcher, $dc, $completions) = build_dispatcher(activities => [$fn]);
    my $run_f = $dispatcher->dispatch_task(start_task_bytes($dc, $token, 'waiter'));
    await_f($dispatcher->dispatch_task($cancel_bytes));
    await_f($run_f);
    $seen{completions} = $completions;
    return \%seen;
}

T2->subtest('WORKER_SHUTDOWN cancel: reason + worker_shutdown flag reported' => sub {
    my $token = 'tok-shutdown';
    my $seen  = run_cancelled_activity($token,
        cancel_task_bytes($token, 3, is_worker_shutdown => 1));

    T2->is($seen->{before}, undef,
        'no cancellation_details before the cancel arrives');
    my $details = $seen->{after};
    T2->ok(defined $details, 'body observed cancellation_details after waking');
    T2->is($details->reason, 'WORKER_SHUTDOWN', 'reason names the cancel cause');
    T2->ok($details->worker_shutdown,   'worker_shutdown flag set');
    T2->ok(!$details->cancel_requested, 'cancel_requested unset');
    T2->ok(!$details->paused,           'paused unset');
    T2->ok(!$details->not_found,        'not_found unset');
    T2->ok(!$details->timed_out,        'timed_out unset');
    T2->ok(!$details->reset,            'reset unset');
    T2->ok($seen->{pkg_same},
        'Temporalio::Activity::cancellation_details() returns the same object');

    my $comp = $Completion->decode($seen->{completions}[0]);
    T2->is($comp->result->which_status, 'cancelled',
        'the activity still completes cancelled');
});

T2->subtest('PAUSED cancel: reason + paused flag reported' => sub {
    my $token = 'tok-paused';
    my $seen  = run_cancelled_activity($token,
        cancel_task_bytes($token, 4, is_paused => 1));

    my $details = $seen->{after};
    T2->ok(defined $details, 'body observed cancellation_details after waking');
    T2->is($details->reason, 'PAUSED', 'reason names the cancel cause');
    T2->ok($details->paused,            'paused flag set');
    T2->ok(!$details->worker_shutdown,  'worker_shutdown unset');
    T2->ok(!$details->cancel_requested, 'cancel_requested unset');
});

T2->subtest('un-cancelled activity reports no cancellation_details' => sub {
    my $observed = 'sentinel';
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'calm',
        code => async sub (@) {
            $observed = Temporalio::Activity::context()->cancellation_details;
            return 'done';
        },
    );
    my ($dispatcher, $dc, $completions) = build_dispatcher(activities => [$fn]);
    await_f($dispatcher->dispatch_task(
        start_task_bytes($dc, 'tok-calm', 'calm')));

    T2->is($observed, undef, 'cancellation_details is undef when never cancelled');
    my $comp = $Completion->decode($completions->[0]);
    T2->is($comp->result->which_status, 'completed', 'activity completed');
});

T2->subtest('directly-constructed context (no holder) reports undef' => sub {
    # The fork-pool child builds its own context with no dispatcher holder;
    # the accessor must degrade to undef, not die.
    my $ctx = Temporalio::Activity::Context->new(
        info               => { task_token => 't' },
        cancellation       => Temporalio::Cancellation->new,
        data_converter     => Temporalio::Converter::Data->new,
        heartbeat_recorder => sub ($bytes) { return undef },
    );
    T2->is($ctx->cancellation_details, undef,
        'undef without a dispatcher-shared holder');
});

T2->done_testing;
