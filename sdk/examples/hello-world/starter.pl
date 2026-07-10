#!/usr/bin/env perl
# ABOUTME: hello-world example starter — connects a client, starts the
# ABOUTME: GreetingWorkflow, waits for its result, and prints the greeting. Run
# ABOUTME: the worker (worker.pl) first so there is something to execute it.
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
my $task_queue = $ENV{TEMPORAL_TASK_QUEUE} // 'hello-world';

# Who to greet (first CLI arg), defaulting to Temporal.
my $name = $ARGV[0] // 'Temporal';

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $client = $loop->await(Temporalio::Client->connect(
    $target,
    namespace => $namespace,
    runtime   => $runtime,
))->get;

# execute_workflow starts the workflow and awaits its result in one call. The
# workflow id must be unique per logical execution; reuse it to deduplicate.
my $result = $loop->await($client->execute_workflow(
    'GreetingWorkflow',
    [$name],
    id         => 'hello-world-' . $name,
    task_queue => $task_queue,
))->get;

say $result;       # "Hello, $name!"

$client->connection->close;
$runtime->shutdown;
