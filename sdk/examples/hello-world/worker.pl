#!/usr/bin/env perl
# ABOUTME: hello-world example worker — connects to the server, registers the
# ABOUTME: GreetingWorkflow + SayHello activity, and runs the poll loops until
# ABOUTME: interrupted (Ctrl-C). Run `temporal server start-dev` first.
use v5.38;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/lib";

use Future::AsyncAwait;
use IO::Async::Loop;
use Temporalio::Runtime;
use Temporalio::Client;
use Temporalio::Worker;

use HelloWorld::GreetingWorkflow;
use HelloWorld::Activities;

# host:port of the Temporal frontend. Defaults to the local dev server.
my $target     = $ENV{TEMPORAL_ADDRESS}    // 'localhost:7233';
my $namespace  = $ENV{TEMPORAL_NAMESPACE}  // 'default';
my $task_queue = $ENV{TEMPORAL_TASK_QUEUE} // 'hello-world';

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

# Connect a client (the worker polls through it).
my $client = $loop->await(Temporalio::Client->connect(
    $target,
    namespace => $namespace,
    runtime   => $runtime,
))->get;

# Build the worker: one workflow type, one activity. Names are class strings;
# the worker `require`s them lazily and reads their :Run / :Defn registries.
my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => ['HelloWorld::GreetingWorkflow'],
    activities => ['HelloWorld::Activities'],
);

say "Worker polling task queue '$task_queue' on $target (Ctrl-C to stop)...";

# Stop cleanly on SIGINT/SIGTERM: initiate shutdown so the poll loops drain and
# `run` returns (which finalizes + frees the worker and reaps the fork pool).
for my $sig (qw(INT TERM)) {
    $loop->watch_signal($sig => sub {
        say "\nShutting down...";
        $worker->shutdown;
    });
}

# Drive the activity + workflow poll loops until shutdown.
$loop->await($worker->run)->get;
say 'Worker stopped.';
