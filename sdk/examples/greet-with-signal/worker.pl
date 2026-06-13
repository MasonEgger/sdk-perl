#!/usr/bin/env perl
# ABOUTME: greet-with-signal example worker — connects to the server, registers
# ABOUTME: the signal-driven GreetingWorkflow, and runs the poll loop until
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

use GreetWithSignal::GreetingWorkflow;

# host:port of the Temporal frontend. Defaults to the local dev server.
my $target     = $ENV{TEMPORAL_ADDRESS}    // 'localhost:7233';
my $namespace  = $ENV{TEMPORAL_NAMESPACE}  // 'default';
my $task_queue = $ENV{TEMPORAL_TASK_QUEUE} // 'greet-with-signal';

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

# Connect a client (the worker polls through it).
my $client = $loop->await(Temporalio::Client->connect(
    $target,
    namespace => $namespace,
    runtime   => $runtime,
))->get;

# Build the worker: one signal-driven workflow type, no activities. The workflow
# class string is `require`d lazily; the worker reads its :Run / :Signal /
# :Query registries.
my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => ['GreetWithSignal::GreetingWorkflow'],
    activities => [],
);

say "Worker polling task queue '$task_queue' on $target (Ctrl-C to stop)...";

# Stop cleanly on SIGINT/SIGTERM: initiate shutdown so the poll loop drains and
# `run` returns (which finalizes + frees the worker).
for my $sig (qw(INT TERM)) {
    $loop->watch_signal($sig => sub {
        say "\nShutting down...";
        $worker->shutdown;
    });
}

# Drive the workflow poll loop until shutdown.
$loop->await($worker->run)->get;
say 'Worker stopped.';
