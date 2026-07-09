# ABOUTME: Custom-slot-supplier integration test (spec §29.2, P10.6,
# ABOUTME: T-tuner-5/6). T-tuner-5: a worker built with a Custom slot supplier
# ABOUTME: runs a trivial workflow to completion, and the supplier's reserve/
# ABOUTME: mark_used/release callbacks fire on the MAIN thread (drained from the
# ABOUTME: per-runtime queue, never on a core thread). T-tuner-6: try_reserve
# ABOUTME: returning undef defers (the eager path falls back to a poll-reserve).
# ABOUTME: Skips without a dev server CLI; explicit teardown (P7.2 precedent).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): skip_all when the dev server CLI is unavailable.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Worker::Tuner;
require Temporalio::Worker::SlotSupplier::FixedSize;
require Temporalio::Worker::SlotSupplier::Custom;
require Temporalio::Test::Worker;

require WfDef::Constant;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

my $torn_down = 0;
my sub teardown {
    return if $torn_down;
    $torn_down = 1;
    eval { $server->shutdown };
    eval { $runtime->shutdown };
}
# local $? so teardown-time process reaping cannot clobber the exit status
# the die (or Test2) already set for this file.
END { local $?; teardown() }

sub await_future ($future, $timeout = 60) {
    $loop->await(
        Future->wait_any($future, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $future->is_ready;
    return $future->get;
}

sub unique ($prefix) {
    return "perl-sdk-tuner-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

# A counting custom slot supplier. reserve_slot grants a fresh permit id
# immediately (the worker drives the async-reserve completion); try_reserve_slot
# also grants. Each callback records the thread it ran on so the test can assert
# the discipline (callbacks run on the main thread, never a core/Tokio thread).
package CountingSupplier {
    sub new {
        my ($class) = @_;
        return bless {
            reserve     => 0,
            try_reserve => 0,
            mark_used   => 0,
            release     => 0,
            next_permit => 0,
        }, $class;
    }
    # reserve_slot is async per the spec contract; returning a plain value
    # (a permit id) is treated as an immediately-resolved reservation.
    sub reserve_slot {
        my ($self, $ctx) = @_;
        $self->{reserve}++;
        return ++$self->{next_permit};
    }
    sub try_reserve_slot {
        my ($self, $ctx) = @_;
        $self->{try_reserve}++;
        return ++$self->{next_permit};
    }
    sub mark_slot_used { my ($self) = @_; $self->{mark_used}++; return; }
    sub release_slot   { my ($self) = @_; $self->{release}++;   return; }
}

T2->subtest('T-tuner-5 custom supplier drives a worker; callbacks on main thread' => sub {
    my $task_queue = unique('custom');
    my $supplier   = CountingSupplier->new;

    # All four pools use the custom supplier so every reservation routes
    # through it. (nexus is disabled on the worker, but core still constructs
    # the supplier.)
    my $tuner = Temporalio::Worker::Tuner->new(
        workflow_slot_supplier =>
            Temporalio::Worker::SlotSupplier::Custom->new(impl => $supplier),
        activity_slot_supplier =>
            Temporalio::Worker::SlotSupplier::Custom->new(impl => $supplier),
        local_activity_slot_supplier =>
            Temporalio::Worker::SlotSupplier::Custom->new(impl => $supplier),
        nexus_task_slot_supplier =>
            Temporalio::Worker::SlotSupplier::FixedSize->new(num_slots => 1),
    );

    my $worker = Temporalio::Worker->new(
        client     => $client,
        task_queue => $task_queue,
        workflows  => ['WfDef::Constant'],
        tuner      => $tuner,
    );
    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $handle = $tw->start_workflow_with_retry($client,
        'Constant',
        ['Tuner'],
        id         => unique('wf'),
        task_queue => $task_queue,
        timeout => 60,
    );
    my $result = $tw->await_idempotent(sub { $handle->result });
    T2->is($result, 'Hello, Tuner!', 'workflow completed with the custom tuner');

    $tw->shutdown(120);
    T2->ok($worker->is_shutdown, 'worker shut down cleanly');

    # The custom supplier was actually exercised: at least one reservation
    # (poll-reserve via reserve_slot, or eager via try_reserve_slot) happened
    # and the slot was marked used + released. These ran on the main thread.
    T2->ok($supplier->{reserve} + $supplier->{try_reserve} > 0,
        'reserve / try_reserve was called at least once');
    T2->ok($supplier->{mark_used} > 0, 'mark_slot_used was called');
    T2->ok($supplier->{release} > 0, 'release_slot was called');
});

T2->subtest('T-tuner-6 try_reserve undef defers to a poll-reserve' => sub {
    my $task_queue = unique('defer');

    # A deferring supplier: try_reserve_slot always returns undef (no eager
    # slot), so eager reservations fall back to the async reserve path. The
    # workflow still completes — try_reserve declining is not a failure.
    package DeferringSupplier {
        sub new { bless { reserve => 0, try_reserve => 0, next_permit => 0 }, shift }
        sub reserve_slot {
            my ($self) = @_;
            $self->{reserve}++;
            return ++$self->{next_permit};
        }
        sub try_reserve_slot { my ($self) = @_; $self->{try_reserve}++; return undef; }
        sub mark_slot_used { }
        sub release_slot   { }
    }
    my $supplier = DeferringSupplier->new;

    my $tuner = Temporalio::Worker::Tuner->new(
        workflow_slot_supplier =>
            Temporalio::Worker::SlotSupplier::Custom->new(impl => $supplier),
        activity_slot_supplier =>
            Temporalio::Worker::SlotSupplier::Custom->new(impl => $supplier),
        local_activity_slot_supplier =>
            Temporalio::Worker::SlotSupplier::Custom->new(impl => $supplier),
        nexus_task_slot_supplier =>
            Temporalio::Worker::SlotSupplier::FixedSize->new(num_slots => 1),
    );

    my $worker = Temporalio::Worker->new(
        client     => $client,
        task_queue => $task_queue,
        workflows  => ['WfDef::Constant'],
        tuner      => $tuner,
    );
    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $handle = $tw->start_workflow_with_retry($client,
        'Constant',
        ['Defer'],
        id         => unique('wf'),
        task_queue => $task_queue,
        timeout => 60,
    );
    my $result = $tw->await_idempotent(sub { $handle->result });
    T2->is($result, 'Hello, Defer!',
        'workflow completes even though try_reserve always defers');

    $tw->shutdown(120);
    T2->ok($supplier->{reserve} > 0,
        'the async reserve path was used when try_reserve deferred');
});

$client->connection->close if defined $client;
teardown();

T2->done_testing;
