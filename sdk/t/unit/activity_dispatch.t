# ABOUTME: Unit tests for the async activity dispatcher + poll loop (spec
# ABOUTME: section 8.4): start/cancel routing, completion building, codec
# ABOUTME: boundary, the task_token running-activities map, and shutdown
# ABOUTME: (T-act-5, T-act-8, T-act-9, T-wkr-4).
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

use Temporalio::Cancellation ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Application ();
use Temporalio::Worker::ActivityRegistry ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::PollLoop ();
use Temporalio::Activity::FunctionDefinition ();

my $loop = IO::Async::Loop->new;

# These Futures resolve synchronously (in-memory converters, injected poll
# sources, activity bodies that park only on the explicit Future we control),
# so ->get drives them to completion without running the loop. Matches the
# pattern in converter_data.t.
sub await_f ($f) { return $f->get }

# Resolve the proto message classes we craft tasks from / decode completions to.
my $ActivityTask = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityTask');
my $Start        = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.Start');
my $Cancel       = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.Cancel');
my $WorkflowExecution = Temporalio::Core::Proto::resolve(
    'temporal.api.common.v1.WorkflowExecution');
my $Completion = Temporalio::Core::Proto::resolve('coresdk.ActivityTaskCompletion');

# Build a serialized ActivityTask with a `start` variant for $type, encoding
# @args through $dc (so the dispatcher's decode is exercised end to end).
sub start_task_bytes ($dc, $token, $type, @args) {
    my @payloads = await_f($dc->to_payloads([@args]));
    my $start = $Start->new({
        workflow_namespace => 'default',
        workflow_type      => 'GreetWorkflow',
        workflow_execution => $WorkflowExecution->new({
            workflow_id => 'wf-1', run_id => 'run-1' }),
        activity_id   => 'act-1',
        activity_type => $type,
        input         => [@payloads],
        attempt       => 1,
    });
    return $ActivityTask->new({ task_token => $token, start => $start })->encode;
}

sub cancel_task_bytes ($token) {
    return $ActivityTask->new({
        task_token => $token,
        cancel     => $Cancel->new({}),
    })->encode;
}

# A minimal data converter (no codecs) plus a fake client carrying it.
sub new_dc { Temporalio::Converter::Data->new }

class FakeClient {
    field $data_converter :param;
    field $namespace      :param = 'default';
    field $identity       :param = 'pid@host';
    method data_converter { $data_converter }
    method namespace      { $namespace }
    method identity       { $identity }
}

# Build a dispatcher over a one-activity registry. $completions is an arrayref
# the injected completer pushes raw completion bytes onto.
sub build_dispatcher (%args) {
    my $dc          = $args{data_converter} // new_dc();
    my $registry    = Temporalio::Worker::ActivityRegistry->new(
        activities => $args{activities});
    my $completions = $args{completions} // [];
    my $heartbeats  = $args{heartbeats}  // [];
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
        heartbeat_recorder => sub ($bytes) {
            push @$heartbeats, $bytes;
            return undef;
        },
    );
    return ($dispatcher, $dc, $completions, $heartbeats);
}

T2->subtest('start task: runs the async activity and completes with the encoded result (T-act-5)' => sub {
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'greet',
        code => async sub ($name) { return "Hello, $name!" },
    );
    my ($dispatcher, $dc, $completions) = build_dispatcher(activities => [$fn]);

    my $token = 'tok-greet';
    my $bytes = start_task_bytes($dc, $token, 'greet', 'World');
    await_f($dispatcher->dispatch_task($bytes));

    T2->is(scalar(@$completions), 1, 'one completion sent');
    my $comp = $Completion->decode($completions->[0]);
    T2->is($comp->task_token, $token, 'completion carries the task token');
    T2->is($comp->result->which_status, 'completed', 'status is completed');
    my $payload = $comp->result->completed->result;
    my ($value) = await_f($dc->from_payloads([$payload]));
    T2->is($value, 'Hello, World!', 'result payload round-trips to the value');
});

T2->subtest('start task: a die in the body completes failed with the cause type preserved (T-act-8)' => sub {
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'boom',
        code => async sub (@) {
            Temporalio::Exception::Application->throw(
                message => 'kaboom', type => 'X');
        },
    );
    my ($dispatcher, $dc, $completions) = build_dispatcher(activities => [$fn]);

    my $bytes = start_task_bytes($dc, 'tok-boom', 'boom');
    await_f($dispatcher->dispatch_task($bytes));

    T2->is(scalar(@$completions), 1, 'one completion sent');
    my $comp = $Completion->decode($completions->[0]);
    T2->is($comp->result->which_status, 'failed', 'status is failed');
    my $failure = $comp->result->failed->failure;
    T2->is($failure->message, 'kaboom', 'failure message preserved');
    T2->is($failure->application_failure_info->type, 'X',
        'ApplicationError type preserved on the wire');
});

T2->subtest('cancel task: cancels the running activity token; awaiting body completes cancelled (T-act-9)' => sub {
    my $released = Future->new;
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'waiter',
        code => async sub (@) {
            my $ctx = Temporalio::Activity::context();
            await $ctx->cancellation->cancelled;
            Temporalio::Exception::Cancelled->throw(message => 'activity cancelled');
        },
    );
    my ($dispatcher, $dc, $completions) = build_dispatcher(activities => [$fn]);

    my $token = 'tok-wait';
    my $start = start_task_bytes($dc, $token, 'waiter');
    my $run_f = $dispatcher->dispatch_task($start);   # do NOT await yet

    # While the activity is parked on its cancellation, it must be in the map.
    T2->ok($dispatcher->is_running($token), 'running activity registered');

    # Deliver the cancel task: it must resolve the activity's cancellation.
    await_f($dispatcher->dispatch_task(cancel_task_bytes($token)));
    await_f($run_f);

    T2->is(scalar(@$completions), 1, 'one completion sent (from the start task)');
    my $comp = $Completion->decode($completions->[0]);
    T2->is($comp->result->which_status, 'cancelled', 'status is cancelled');
    T2->ok(!$dispatcher->is_running($token),
        'running activity removed after completion');
});

T2->subtest('cancel for an unknown task token logs + drops' => sub {
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'noop', code => async sub (@) { 'ok' });
    my ($dispatcher, $dc, $completions) = build_dispatcher(activities => [$fn]);

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    await_f($dispatcher->dispatch_task(cancel_task_bytes('ghost-token')));

    T2->is(scalar(@$completions), 0, 'no completion for an unknown cancel');
    T2->ok(scalar(@warnings) >= 1, 'a warning was emitted');
    T2->like($warnings[0], qr/ghost-token|cancel/i,
        'warning mentions the missing token');
});

T2->subtest('codec decode on start.input and encode on the completion payloads' => sub {
    # A spy codec that records every encode/decode call and otherwise passes
    # payloads through unchanged.
    my @calls;
    my $codec = SpyCodec->new(log => \@calls);
    my $dc = Temporalio::Converter::Data->new(payload_codecs => [$codec]);

    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'echo', code => async sub ($x) { return uc $x });
    my ($dispatcher) = build_dispatcher(activities => [$fn], data_converter => $dc);

    # Craft the start task with the SAME codec-aware converter so input is
    # codec-encoded on the wire; the dispatcher must decode it before the body.
    my $bytes = start_task_bytes($dc, 'tok-echo', 'echo', 'hi');
    await_f($dispatcher->dispatch_task($bytes));

    T2->ok((grep { $_ eq 'decode' } @calls), 'codec decode applied to start.input');
    T2->ok((grep { $_ eq 'encode' } @calls), 'codec encode applied to the completion');
});

T2->subtest('running-activities map adds on start and removes on completion' => sub {
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'quick', code => async sub (@) { 'done' });
    my ($dispatcher, $dc) = build_dispatcher(activities => [$fn]);

    my $token = 'tok-quick';
    T2->ok(!$dispatcher->is_running($token), 'not running before dispatch');
    await_f($dispatcher->dispatch_task(start_task_bytes($dc, $token, 'quick')));
    T2->ok(!$dispatcher->is_running($token), 'removed once the activity completed');
});

T2->subtest('unregistered activity type completes failed (not-found)' => sub {
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'known', code => async sub (@) { 'ok' });
    my ($dispatcher, $dc, $completions) = build_dispatcher(activities => [$fn]);

    await_f($dispatcher->dispatch_task(
        start_task_bytes($dc, 'tok-missing', 'unknown_activity')));

    T2->is(scalar(@$completions), 1, 'completion sent for the unknown type');
    my $comp = $Completion->decode($completions->[0]);
    T2->is($comp->result->which_status, 'failed',
        'unregistered activity completes failed');
});

T2->subtest('poll loop dispatches tasks until the shutdown sentinel, then returns (T-wkr-4)' => sub {
    my @dispatched;
    # A dispatcher stub recording the bytes it is handed.
    my $stub = DispatcherStub->new(log => \@dispatched);

    # An injected poll source: two task byte strings then undef (shutdown).
    my @queue = ('task-a', 'task-b', undef);
    my $poll_source = sub { return Future->done(shift @queue) };

    my $poll_loop = Temporalio::Worker::PollLoop->new(
        dispatcher  => $stub,
        poll_source => $poll_source,
        loop        => $loop,
    );
    await_f($poll_loop->run);

    T2->is(\@dispatched, ['task-a', 'task-b'],
        'each non-undef task dispatched; the loop returned on the sentinel');
});

T2->subtest('a second shutdown / empty poll source returns immediately (T-wkr-4)' => sub {
    my @dispatched;
    my $stub = DispatcherStub->new(log => \@dispatched);
    my $poll_source = sub { return Future->done(undef) };   # immediate sentinel
    my $poll_loop = Temporalio::Worker::PollLoop->new(
        dispatcher  => $stub,
        poll_source => $poll_source,
        loop        => $loop,
    );
    await_f($poll_loop->run);
    T2->is(\@dispatched, [], 'no tasks dispatched, loop returned at once');
});

T2->done_testing;

# --- test doubles ---------------------------------------------------------
# Plain (non-class) packages so they coexist in one file with Future::AsyncAwait
# loaded (only one `class :isa(...)` parses per file — lessons.md). These need
# no inheritance, so a blessed-hash package is simplest.

package SpyCodec {
    use Future ();
    sub new ($class, %args) { return bless { log => $args{log} }, $class }
    sub encode ($self, $payloads) {
        push @{ $self->{log} }, 'encode';
        return Future->done($payloads);
    }
    sub decode ($self, $payloads) {
        push @{ $self->{log} }, 'decode';
        return Future->done($payloads);
    }
}

package DispatcherStub {
    use Future ();
    sub new ($class, %args) { return bless { log => $args{log} }, $class }
    sub dispatch_task ($self, $bytes) {
        push @{ $self->{log} }, $bytes;
        return Future->done;
    }
}
