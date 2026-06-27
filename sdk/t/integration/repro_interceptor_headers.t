# ABOUTME: B11 live smoke (#10 C-ICEPT-HEADERS): a header set at workflow start
# ABOUTME: must reach the worker workflow-inbound hook as a REAL non-empty value.
# ABOUTME: Before the fix the Runner built the inbound ExecuteWorkflow input with
# ABOUTME: no headers, so context propagation forwarded an empty map and the
# ABOUTME: downstream activity read request_id=(none). Not a crash/hang -> in-process.
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Pure-Perl (no FFI): loaded at compile time so the inbound-base subclass below
# resolves its :isa at BEGIN, even on machines without the dev server.
use Temporalio::Worker::Interceptor ();
use Temporalio::Converter::Payload ();

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

# The request id propagated as a start header. The inbound hook must read THIS
# value, not an empty map (which would decode to undef / "(none)").
my $REQUEST_ID = 'rid-live-' . $$ . '-' . int(rand(1_000_000));
my $PC = Temporalio::Converter::Payload->default;
my @seen_request_ids;

# A worker workflow-inbound interceptor that reads the start header off the
# execute_workflow input (the #10 fix threads it in from InitializeWorkflow) and
# records the decoded request id. Classic `feature 'class'` subclass of the
# inbound base; signature-less method per project convention.
class HeaderReadingInbound :isa(Temporalio::Worker::WorkflowInbound) {
    method execute_workflow {
        my $headers = $_[0]->headers // {};
        if (my $p = $headers->{_request_id}) {
            push @seen_request_ids, $PC->from_payload($p);
        }
        else {
            push @seen_request_ids, '(none)';
        }
        return $self->next->execute_workflow($_[0]);
    }
}
class HeaderReadingInterceptor :isa(Temporalio::Worker::Interceptor) {
    method intercept_workflow {
        return HeaderReadingInbound->new(next => $_[0]);
    }
}

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

my $task_queue = 'perl-sdk-b11-icept-hdr-' . $$ . '-' . int(rand(1_000_000));

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
    interceptors => [ HeaderReadingInterceptor->new ],
);

my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

my $ok = eval {
    my $handle = $tw->start_workflow_with_retry($client,
        'E2EGreeting',
        ['Bob'],
        id         => "perl-sdk-b11-icept-hdr-wf-$$-" . int(rand(1_000_000)),
        task_queue => $task_queue,
        headers    => { _request_id => $REQUEST_ID },
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

# The workflow-inbound hook read the REAL start header forwarded by the client,
# not an empty map (#10). Before the fix @seen_request_ids would be all '(none)'.
T2->ok(scalar(@seen_request_ids), 'the workflow-inbound hook ran at least once');
T2->ok((grep { $_ eq $REQUEST_ID } @seen_request_ids),
    "the inbound hook read the real start header request id ($REQUEST_ID), not (none)");
T2->ok(!(grep { $_ eq '(none)' } @seen_request_ids),
    'the inbound hook never saw an empty header map');

T2->done_testing;
