# ABOUTME: Unit tests for spec R85 (parity activity/conversion finding 5): the
# ABOUTME: activity Info surfaces priority and retry_policy from the
# ABOUTME: ActivityTask.Start job, and both stay absent when the job omits them.
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
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::ActivityRegistry ();

my $loop = IO::Async::Loop->new;

# Declared BEFORE any signatured sub: on 5.38.2 a signatured named sub
# immediately preceding a `class` block makes `field ... :param` die with
# "Subroutine attributes must come before the signature" (parser bug; a
# signature-less sub in between also resets it -- see lessons.md).
class FakeClient {
    field $data_converter :param;
    method data_converter { $data_converter }
    method namespace      { 'default' }
    method identity       { 'pid@host' }
}

# These Futures resolve synchronously (in-memory converter, bodies that never
# park), so ->get drives them without running the loop (activity_dispatch.t
# pattern).
sub await_f ($f) { return $f->get }

my $ActivityTask = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityTask');
my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
my $WorkflowExecution = Temporalio::Core::Proto::resolve(
    'temporal.api.common.v1.WorkflowExecution');
my $RetryPolicy = Temporalio::Core::Proto::resolve(
    'temporal.api.common.v1.RetryPolicy');
my $Priority = Temporalio::Core::Proto::resolve(
    'temporal.api.common.v1.Priority');
my $Duration   = Temporalio::Core::Proto::resolve('google.protobuf.Duration');
my $Completion = Temporalio::Core::Proto::resolve('coresdk.ActivityTaskCompletion');

# Serialized start task for $type; %extra lands on the Start message verbatim
# (retry_policy / priority for the cases below).
sub start_task_bytes ($dc, $token, $type, %extra) {
    my @payloads = await_f($dc->to_payloads(['x']));
    my $start = $Start->new({
        workflow_namespace => 'default',
        workflow_type      => 'InfoWorkflow',
        workflow_execution => $WorkflowExecution->new({
            workflow_id => 'wf-1', run_id => 'run-1' }),
        activity_id   => 'act-1',
        activity_type => $type,
        input         => [@payloads],
        attempt       => 1,
        %extra,
    });
    return $ActivityTask->new({ task_token => $token, start => $start })->encode;
}

# Dispatcher over a one-activity registry whose body captures its Info hashref
# into $captured.
sub build_dispatcher ($captured, $completions) {
    my $dc = Temporalio::Converter::Data->new;
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'capture_info',
        code => async sub (@) {
            $$captured = Temporalio::Activity::context()->info;
            return 'ok';
        },
    );
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => Temporalio::Worker::ActivityRegistry->new(
            activities => [$fn]),
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
    return ($dispatcher, $dc);
}

T2->subtest('start job with retry_policy surfaces it on the activity Info (R85)' => sub {
    my ($captured, @completions);
    my ($dispatcher, $dc) = build_dispatcher(\$captured, \@completions);

    my $bytes = start_task_bytes($dc, 'tok-retry', 'capture_info',
        retry_policy => $RetryPolicy->new({
            initial_interval    => $Duration->new({ seconds => 1 }),
            backoff_coefficient => 2.0,
            maximum_attempts    => 5,
        }),
    );
    await_f($dispatcher->dispatch_task($bytes));

    my $rp = $captured->{retry_policy};
    T2->ok(defined $rp, 'retry_policy present on the Info');
    T2->is($rp->initial_interval->seconds, 1,
        'initial interval carried through');
    T2->is($rp->backoff_coefficient, 2.0, 'backoff coefficient carried through');
    T2->is($rp->maximum_attempts, 5, 'maximum attempts carried through');
});

T2->subtest('start job with priority surfaces it on the activity Info (R85)' => sub {
    my ($captured, @completions);
    my ($dispatcher, $dc) = build_dispatcher(\$captured, \@completions);

    my $bytes = start_task_bytes($dc, 'tok-priority', 'capture_info',
        priority => $Priority->new({
            priority_key    => 1,
            fairness_key    => 'tenant-a',
            fairness_weight => 2.5,
        }),
    );
    await_f($dispatcher->dispatch_task($bytes));

    my $pri = $captured->{priority};
    T2->ok(defined $pri, 'priority present on the Info');
    T2->is($pri->priority_key, 1, 'priority key carried through');
    T2->is($pri->fairness_key, 'tenant-a', 'fairness key carried through');
    T2->is($pri->fairness_weight, 2.5, 'fairness weight carried through');
});

T2->subtest('start job with neither yields absent fields without error (R85 edge)' => sub {
    my ($captured, @completions);
    my ($dispatcher, $dc) = build_dispatcher(\$captured, \@completions);

    my $bytes = start_task_bytes($dc, 'tok-bare', 'capture_info');
    await_f($dispatcher->dispatch_task($bytes));

    T2->ok(exists $captured->{retry_policy},
        'retry_policy key present on the Info');
    T2->ok(!defined $captured->{retry_policy}, 'retry_policy is undef');
    T2->ok(exists $captured->{priority}, 'priority key present on the Info');
    T2->ok(!defined $captured->{priority}, 'priority is undef');

    T2->is(scalar(@completions), 1, 'activity still completed');
    my $comp = $Completion->decode($completions[0]);
    T2->is($comp->result->which_status, 'completed',
        'completion status is completed (no error)');
});

T2->done_testing;
