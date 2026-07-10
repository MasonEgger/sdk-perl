# ABOUTME: Custom metric meter compliance (spec section 28.2, T-meter-10):
# ABOUTME: a live worker drives core's internal metrics into a Perl meter.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();
use Scalar::Util ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. Honor TEMPORAL_CLI first, then scan PATH. Never download.
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
require Temporalio::Runtime::MetricMeter;
require Temporalio::Runtime::TelemetryConfig;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require Temporalio::Activity::FunctionDefinition;

require WfDef::E2EGreeting;

# A meter that records every create_metric / record_* core drives. Counts are
# enough for the compliance assertion: core emits internal metrics (workflow
# task latency, poller counts, etc.) while a worker runs.
package CountingMeter {
    use parent -norequire, 'Temporalio::Runtime::MetricMeter';
    sub new ($class) { return bless { created => 0, recorded => 0, names => {} }, $class }
    sub created  ($self) { $self->{created} }
    sub recorded ($self) { $self->{recorded} }
    sub names    ($self) { $self->{names} }
    sub create_metric ($self, $name, $desc, $unit, $kind) {
        $self->{created}++;
        $self->{names}{$name}++;
        return { name => $name };
    }
    sub new_attributes ($self, $append_from, $attributes) { return $attributes }
    sub record_integer  ($self, $metric, $value, $attrs) { $self->{recorded}++ }
    sub record_float    ($self, $metric, $value, $attrs) { $self->{recorded}++ }
    sub record_duration ($self, $metric, $value, $attrs) { $self->{recorded}++ }
}

my $loop  = IO::Async::Loop->new;
my $meter = CountingMeter->new;
my $runtime = Temporalio::Runtime->new(
    loop      => $loop,
    telemetry => Temporalio::Runtime::TelemetryConfig->new(metrics => $meter),
);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Teardown in END so a die mid-file still releases the dev-server CLI child
# (finding T9 / spec R49): DevServer::DESTROY cannot run the event loop, so
# only an END-registered shutdown covers the die path. Enforced by
# xt/devserver_end_teardown.t.
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

sub unique_id ($prefix) {
    return "perl-sdk-metrics-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target, namespace => 'default', runtime => $runtime);
});

my $task_queue = 'perl-sdk-metrics-' . $$ . '-' . int(rand(1_000_000));

my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::E2EGreeting)],
    activities => [
        Temporalio::Activity::FunctionDefinition->new(
            name => 'SayHello',
            code => sub ($name) { return "Hello, $name!" },
        ),
    ],
);
my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

# Run a workflow so core does real work and emits internal metrics through the
# custom meter (T-meter-10).
my $handle = $tw->start_workflow_with_retry($client,
    'E2EGreeting',
    ['Metrics'],
    id         => unique_id('greeting'),
    task_queue => $task_queue,
    timeout => 60,
);
my $result = $tw->await_idempotent(sub { $handle->result });
T2->is($result, 'Hello, Metrics!', 'workflow ran under the custom meter');

# Pump the loop briefly so any final marshalled meter requests / aggregated
# records drain to the Perl meter.
$loop->await($loop->delay_future(after => 0.5));

T2->ok($meter->created > 0,
    'core created at least one metric through the custom meter (T-meter-10)')
    or T2->diag('created=' . $meter->created);
T2->ok($meter->recorded > 0,
    'core recorded at least one value through the custom meter')
    or T2->diag('recorded=' . $meter->recorded);

# Explicit teardown (P7.2 precedent): drain the worker, close the client, stop
# the server, and shut the runtime down so the -j4 harness never wedges on an
# orphaned dev server.
$tw->shutdown(120);
$client->connection->close if defined $client;
teardown();

T2->done_testing;
