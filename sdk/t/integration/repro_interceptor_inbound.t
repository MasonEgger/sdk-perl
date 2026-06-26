# ABOUTME: B7 repro / regression guard (#10 C-ICEPT): a worker-supplied INBOUND
# ABOUTME: interceptor must observe the live workflow AND activity execution. The
# ABOUTME: dispatch path used to build but never call the inbound chains, so an
# ABOUTME: inbound interceptor was silently bypassed end to end. Not a crash/hang,
# ABOUTME: so this runs in-process (no subprocess guard).
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Pure-Perl (no FFI): loaded at compile time so the inbound-base subclasses
# below resolve their :isa at BEGIN, even on machines without the dev server.
use Temporalio::Worker::Interceptor ();

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. Honor TEMPORAL_CLI first, then scan PATH. No download attempted.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Loaded after the gate so machines without the CLI never compile the FFI stack.
require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require Temporalio::Activity::FunctionDefinition;
require WfDef::E2EGreeting;

# A worker interceptor whose inbound links record onto a shared trace. Classic
# `feature 'class'` subclasses of the inbound bases (the only way to extend a
# `field`-bearing base); signature-less methods per the project convention.
class TraceActivityInbound :isa(Temporalio::Worker::ActivityInbound) {
    field $trace :param;
    method execute_activity {
        push @$trace, 'activity';
        return $self->next->execute_activity($_[0]);
    }
}
class TraceWorkflowInbound :isa(Temporalio::Worker::WorkflowInbound) {
    field $trace :param;
    method execute_workflow {
        push @$trace, 'workflow';
        return $self->next->execute_workflow($_[0]);
    }
}
class TraceInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $trace :param;
    method intercept_activity {
        return TraceActivityInbound->new(next => $_[0], trace => $trace);
    }
    method intercept_workflow {
        return TraceWorkflowInbound->new(next => $_[0], trace => $trace);
    }
}

my @trace;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $task_queue = 'perl-sdk-b7-icept-' . $$ . '-' . int(rand(1_000_000));

my $worker = Temporalio::Worker->new(
    client       => $client,
    task_queue   => $task_queue,
    workflows    => [qw(WfDef::E2EGreeting)],
    activities   => [
        Temporalio::Activity::FunctionDefinition->new(
            name => 'SayHello',
            code => sub ($name) { return "Hello, $name!" },
        ),
    ],
    interceptors => [ TraceInterceptor->new(trace => \@trace) ],
);

my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

my $ok = eval {
    my $handle = $tw->start_workflow_with_retry($client,
        'E2EGreeting',
        ['Bob'],
        id         => "perl-sdk-b7-icept-wf-$$-" . int(rand(1_000_000)),
        task_queue => $task_queue,
    );
    my $result = $tw->await_result($handle->result, 120);
    T2->is($result, 'Hello, Bob!', 'workflow returned the activity greeting');
    1;
};
my $err = $@;

eval { $tw->shutdown(30); 1 };
eval { $client->connection->close; 1 };
eval { $server->shutdown; 1 };
$runtime->shutdown;

die $err if !$ok && $err;

# The inbound interceptor observed BOTH the workflow run and the activity
# execution (#10): before the fix the dispatch path never called the chain, so
# @trace stayed empty.
T2->ok((grep { $_ eq 'workflow' } @trace),
    'inbound interceptor observed the workflow execution (#10)');
T2->ok((grep { $_ eq 'activity' } @trace),
    'inbound interceptor observed the activity execution (#10)');

T2->done_testing;
