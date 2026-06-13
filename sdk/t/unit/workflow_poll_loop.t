# ABOUTME: Unit tests for the workflow dispatcher + poll loop (spec section 8.3):
# ABOUTME: run_id routing + per-run Runner cache, the eviction fast path
# ABOUTME: (T-wf-14), eviction-last ordering, the codec boundary, and shutdown.
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

use Temporalio::Converter::Data ();
use Temporalio::Converter::Payload ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Worker::WorkflowDispatcher ();
use Temporalio::Worker::PollLoop ();

my $loop = IO::Async::Loop->new;

# Activations the worker feeds the dispatcher resolve synchronously here (the
# Runner drives workflow Futures imperatively, no IO::Async), so ->get pumps
# them to completion. Matches activity_dispatch.t / timers.t.
sub await_f ($f) { return $f->get }

# Proto classes we craft activations from / decode completions to.
my $Activation = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_activation.WorkflowActivation');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_completion.WorkflowActivationCompletion');

my $PC = Temporalio::Converter::Payload->default;
sub payload ($value) { return $PC->to_payload($value) }

# Build a serialized WorkflowActivation. $jobs is the oneof-tagged hashref form.
sub activation_bytes ($run_id, $jobs, %opt) {
    return $Activation->new({
        run_id      => $run_id,
        timestamp   => { seconds => $opt{seconds} // 100 },
        is_replaying => $opt{is_replaying} // 0,
        jobs        => $jobs,
    })->encode;
}

# An InitializeWorkflow job for $type with @args encoded through $dc (so the
# dispatcher's codec decode is exercised end to end).
sub init_job ($dc, $type, @args) {
    my @payloads = await_f($dc->to_payloads([@args]));
    return { initialize_workflow => {
        workflow_type => $type,
        arguments     => [@payloads],
    } };
}

# Build a dispatcher over the given workflow class names. $completions collects
# the raw completion bytes the injected completer is handed.
sub build_dispatcher (%args) {
    my $dc          = $args{data_converter} // Temporalio::Converter::Data->new;
    my $registry    = Temporalio::Worker::WorkflowRegistry->new(
        workflows => $args{workflows});
    my $completions = $args{completions} // [];
    my $dispatcher  = Temporalio::Worker::WorkflowDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
    );
    return ($dispatcher, $dc, $completions);
}

T2->subtest('routes by run_id: a new run creates a Runner, a cached run reuses it' => sub {
    my ($dispatcher, $dc, $completions) =
        build_dispatcher(workflows => ['WfDef::TimerSleeper']);

    # First activation for run r1 (InitializeWorkflow) — the sleeper parks on a
    # timer, so a Runner is created and cached for r1.
    await_f($dispatcher->dispatch_task(
        activation_bytes('r1', [ init_job($dc, 'TimerSleeper', 60) ])));
    T2->ok($dispatcher->has_runner('r1'), 'a Runner is cached for run r1');
    my $runner = $dispatcher->runner('r1');

    # The StartTimer command came back on the first completion.
    T2->is(scalar(@$completions), 1, 'one completion sent for the init activation');
    my $c0 = $Completion->decode($completions->[0]);
    T2->is($c0->run_id, 'r1', 'completion carries the run_id');
    my @cmds0 = ($c0->successful->commands // [])->@*;
    T2->is($cmds0[0]->which_variant, 'start_timer', 'StartTimer emitted on init');

    # Second activation for r1 (FireTimer) must reuse the SAME Runner.
    await_f($dispatcher->dispatch_task(
        activation_bytes('r1', [ { fire_timer => { seq => 1 } } ], seconds => 160)));
    T2->is($dispatcher->runner('r1'), $runner,
        'the cached Runner is reused for a later activation on the same run');

    my $c1 = $Completion->decode($completions->[1]);
    my @cmds1 = ($c1->successful->commands // [])->@*;
    T2->is($cmds1[0]->which_variant, 'complete_workflow_execution',
        'the resumed body completes after FireTimer');
});

T2->subtest('a different run_id gets its own Runner' => sub {
    my ($dispatcher, $dc) =
        build_dispatcher(workflows => ['WfDef::TimerSleeper']);

    await_f($dispatcher->dispatch_task(
        activation_bytes('r1', [ init_job($dc, 'TimerSleeper', 60) ])));
    await_f($dispatcher->dispatch_task(
        activation_bytes('r2', [ init_job($dc, 'TimerSleeper', 60) ])));

    T2->ok($dispatcher->has_runner('r1'), 'run r1 cached');
    T2->ok($dispatcher->has_runner('r2'), 'run r2 cached');
    T2->isnt($dispatcher->runner('r1'), $dispatcher->runner('r2'),
        'distinct runs have distinct Runners');
});

T2->subtest('eviction-only activation: empty success, runner dropped, no workflow code (T-wf-14)' => sub {
    my ($dispatcher, $dc, $completions) =
        build_dispatcher(workflows => ['WfDef::TimerSleeper']);

    # Establish a cached runner for r1.
    await_f($dispatcher->dispatch_task(
        activation_bytes('r1', [ init_job($dc, 'TimerSleeper', 60) ])));
    T2->ok($dispatcher->has_runner('r1'), 'runner cached before eviction');

    # An activation whose only job is RemoveFromCache.
    await_f($dispatcher->dispatch_task(
        activation_bytes('r1',
            [ { remove_from_cache => { message => 'cache full' } } ])));

    T2->ok(!$dispatcher->has_runner('r1'), 'runner dropped after eviction');

    my $c = $Completion->decode($completions->[-1]);
    T2->is($c->run_id, 'r1', 'eviction completion carries the run_id');
    T2->ok(defined $c->successful, 'eviction completion is successful');
    my @cmds = ($c->successful->commands // [])->@*;
    T2->is(scalar(@cmds), 0, 'eviction completion carries no commands (empty success)');
});

T2->subtest('eviction for an uncached run: empty success, no error' => sub {
    my ($dispatcher, undef, $completions) =
        build_dispatcher(workflows => ['WfDef::TimerSleeper']);

    # RemoveFromCache for a run the dispatcher never saw (cache miss) — Python's
    # _handle_cache_eviction tolerates a missing entry.
    await_f($dispatcher->dispatch_task(
        activation_bytes('ghost',
            [ { remove_from_cache => { message => 'cache miss' } } ])));

    T2->is(scalar(@$completions), 1, 'a completion is still sent');
    my $c = $Completion->decode($completions->[0]);
    T2->ok(defined $c->successful, 'empty success for an unknown run eviction');
    T2->is(scalar(($c->successful->commands // [])->@*), 0, 'no commands');
});

T2->subtest('RemoveFromCache combined with other jobs applies eviction last' => sub {
    my ($dispatcher, $dc, $completions) =
        build_dispatcher(workflows => ['WfDef::TimerSleeper']);

    # A single activation carrying BOTH an InitializeWorkflow (which would park
    # on a timer) AND a RemoveFromCache. Eviction is applied last: the runner is
    # torn down and the completion is the empty-success eviction response, but
    # the activation must still be processed without crashing.
    await_f($dispatcher->dispatch_task(
        activation_bytes('r1', [
            init_job($dc, 'TimerSleeper', 60),
            { remove_from_cache => { message => 'lang requested' } },
        ])));

    T2->ok(!$dispatcher->has_runner('r1'),
        'runner is torn down when an activation carries RemoveFromCache');
    my $c = $Completion->decode($completions->[-1]);
    T2->ok(defined $c->successful, 'combined activation still yields a success');
    T2->is(scalar(($c->successful->commands // [])->@*), 0,
        'eviction wins: empty-success completion');
});

T2->subtest('codec decode on inbound activation payloads, encode on outbound completion' => sub {
    my @calls;
    my $codec = SpyCodec->new(log => \@calls);
    my $dc = Temporalio::Converter::Data->new(payload_codecs => [$codec]);

    # WfDef::Constant returns "Hello, $name!" immediately — its init args carry a
    # payload (decode boundary) and its completion carries a result payload
    # (encode boundary).
    my ($dispatcher) =
        build_dispatcher(workflows => ['WfDef::Constant'], data_converter => $dc);

    # Craft the init args with the SAME codec-aware converter so the input is
    # codec-encoded on the wire; the dispatcher must decode it before the runner.
    await_f($dispatcher->dispatch_task(
        activation_bytes('rc', [ init_job($dc, 'Constant', 'World') ])));

    T2->ok((grep { $_ eq 'decode' } @calls),
        'codec decode applied to inbound activation payloads');
    T2->ok((grep { $_ eq 'encode' } @calls),
        'codec encode applied to outbound completion payloads');
});

T2->subtest('poll loop dispatches activations until the shutdown sentinel (T-wkr-4)' => sub {
    my @dispatched;
    my $stub = DispatcherStub->new(log => \@dispatched);

    my @queue = ('act-a', 'act-b', undef);
    my $poll_source = sub { return Future->done(shift @queue) };

    my $poll_loop = Temporalio::Worker::PollLoop->new(
        dispatcher  => $stub,
        poll_source => $poll_source,
        loop        => $loop,
    );
    await_f($poll_loop->run);

    T2->is(\@dispatched, ['act-a', 'act-b'],
        'each non-undef activation dispatched; loop returned on the sentinel');
});

T2->done_testing;

# --- test doubles ---------------------------------------------------------
# Plain (non-class) packages so they coexist in one file with Future::AsyncAwait
# loaded (only one `class :isa(...)` parses per file — lessons.md).

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
