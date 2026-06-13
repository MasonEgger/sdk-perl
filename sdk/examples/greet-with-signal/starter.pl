#!/usr/bin/env perl
# ABOUTME: greet-with-signal example starter — starts the workflow, queries the
# ABOUTME: (empty) name, sends a `setName` signal, queries again, then awaits and
# ABOUTME: prints the greeting. Run the worker (worker.pl) first.
use v5.38;
use warnings;
use utf8;

use Future::AsyncAwait;
use IO::Async::Loop;
use Temporalio::Runtime;
use Temporalio::Client;

# host:port of the Temporal frontend. Defaults to the local dev server.
my $target     = $ENV{TEMPORAL_ADDRESS}    // 'localhost:7233';
my $namespace  = $ENV{TEMPORAL_NAMESPACE}  // 'default';
my $task_queue = $ENV{TEMPORAL_TASK_QUEUE} // 'greet-with-signal';

# Who to greet (first CLI arg), defaulting to Temporal.
my $name = $ARGV[0] // 'Temporal';

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

sub await ($future) { return $loop->await($future)->get }

my $client = await(Temporalio::Client->connect(
    $target,
    namespace => $namespace,
    runtime   => $runtime,
));

# Start the workflow (returns a handle without waiting for the result — the
# workflow is parked on wait_condition until we signal it).
my $handle = await($client->start_workflow(
    'GreetWithSignal',
    [],
    id         => 'greet-with-signal-' . $name,
    task_queue => $task_queue,
));

# Query the in-flight workflow's state before signalling — the name is empty.
my $before = await($handle->query('currentName'));
say "current name before signal: '" . ($before // '') . "'";

# Send the signal that sets the name. The worker's :Signal handler runs and
# unblocks the wait_condition, letting the workflow complete.
await($handle->signal('setName', [$name]));
say "sent setName signal: '$name'";

# Query again — the name is now set (queries observe post-signal state).
my $after = await($handle->query('currentName'));
say "current name after signal:  '" . ($after // '') . "'";

# Await the workflow result — the greeting built from the signalled name.
my $result = await($handle->result);
say $result;       # "Hello, $name!"

$client->connection->close;
$runtime->shutdown;
