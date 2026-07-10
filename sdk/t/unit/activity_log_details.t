# ABOUTME: Unit tests for the activity context logging-detail accessor (spec
# ABOUTME: R96, parity activity/conversion finding 6): log_details yields the
# ABOUTME: documented field set, is built once, and reflects the dispatched
# ABOUTME: task's current attempt (Python parity: activity.py:148-159,479-537).
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

use Temporalio::Activity ();
use Temporalio::Activity::Context ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Cancellation ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::ActivityRegistry ();

my $loop = IO::Async::Loop->new;

# In-memory converters and synchronously-resolving bodies: ->get drives the
# dispatch futures without running the loop (the activity_dispatch.t pattern).
sub await_f ($f) { return $f->get }

# The documented field set (spec R96): exactly what Python's activity
# LoggerAdapter embeds in every log line via Info._logger_details
# (activity.py:148-159, surfaced through the adapter at activity.py:479-537).
my @DOCUMENTED_FIELDS = qw(
    activity_id activity_type attempt namespace task_queue
    workflow_id workflow_run_id workflow_type
);

sub make_context (%overrides) {
    return Temporalio::Activity::Context->new(
        info => {
            activity_id                    => 'act-1',
            activity_type                  => 'SayHello',
            attempt                        => 2,
            task_token                     => "tok\x00en",
            task_queue                     => 'demo',
            workflow_id                    => 'wf-1',
            workflow_run_id                => 'run-1',
            workflow_type                  => 'Greeting',
            namespace                      => 'default',
            heartbeat_details              => [],
            current_attempt_scheduled_time => undef,
            scheduled_time                 => undef,
            started_time                   => undef,
            ($overrides{info} ? %{ $overrides{info} } : ()),
        },
        cancellation       => Temporalio::Cancellation->new,
        data_converter     => Temporalio::Converter::Data->new,
        heartbeat_recorder => sub ($bytes) { return undef },
    );
}

T2->subtest('log_details yields the documented field set (R96)' => sub {
    my $ctx = make_context();
    my $details = $ctx->log_details;

    T2->ref_ok($details, 'HASH', 'log_details returns a hashref');
    T2->is([sort keys %$details], [sort @DOCUMENTED_FIELDS],
        'exactly the documented fields, no extras (no task_token leakage)');
    T2->is($details->{activity_id},     'act-1',    'activity_id');
    T2->is($details->{activity_type},   'SayHello', 'activity_type');
    T2->is($details->{attempt},         2,          'attempt');
    T2->is($details->{namespace},       'default',  'namespace');
    T2->is($details->{task_queue},      'demo',     'task_queue');
    T2->is($details->{workflow_id},     'wf-1',     'workflow_id');
    T2->is($details->{workflow_run_id}, 'run-1',    'workflow_run_id');
    T2->is($details->{workflow_type},   'Greeting', 'workflow_type');
});

T2->subtest('log_details is built once and cached (R96 refactor contract)'
    => sub {
    my $ctx = make_context();
    my $first  = $ctx->log_details;
    my $second = $ctx->log_details;
    T2->is("$first", "$second",
        'repeated calls return the same hashref (built once from Info, '
        . 'Python parity: _Context.logger_details caching, '
        . 'activity.py:229-232)');
});

# --- Edge: the accessor is populated inside a DISPATCHED activity and
# reflects the current attempt from the start job (attempt 3 here).

my $ActivityTask = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityTask');
my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
my $WorkflowExecution = Temporalio::Core::Proto::resolve(
    'temporal.api.common.v1.WorkflowExecution');

class FakeClient {
    field $data_converter :param;
    method data_converter { $data_converter }
    method namespace      { 'default' }
    method identity       { 'pid@host' }
}

T2->subtest('log_details inside a dispatched activity reflects the current '
    . 'attempt (R96)' => sub {
    my $seen;
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'observe',
        code => async sub () {
            $seen = Temporalio::Activity::context()->log_details;
            return 'ok';
        },
    );
    my $dc = Temporalio::Converter::Data->new;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry => Temporalio::Worker::ActivityRegistry->new(
            activities => [$fn]),
        data_converter     => $dc,
        task_queue         => 'log-details-q',
        client             => FakeClient->new(data_converter => $dc),
        loop               => $loop,
        completer          => sub ($bytes) { return Future->done },
        heartbeat_recorder => sub ($bytes) { return undef },
    );

    my $start = $Start->new({
        workflow_namespace => 'ns-log',
        workflow_type      => 'GreetWorkflow',
        workflow_execution => $WorkflowExecution->new({
            workflow_id => 'wf-log', run_id => 'run-log' }),
        activity_id   => 'act-log',
        activity_type => 'observe',
        input         => [],
        attempt       => 3,
    });
    my $bytes = $ActivityTask->new({
        task_token => 'tok-log', start => $start })->encode;
    await_f($dispatcher->dispatch_task($bytes));

    T2->ok(defined $seen, 'log_details populated inside the dispatched body');
    T2->is($seen->{attempt},         3,             'reflects the current attempt');
    T2->is($seen->{activity_id},     'act-log',     'activity_id from the start job');
    T2->is($seen->{activity_type},   'observe',     'activity_type from the start job');
    T2->is($seen->{namespace},       'ns-log',      'namespace from the start job');
    T2->is($seen->{task_queue},      'log-details-q', 'the worker task queue');
    T2->is($seen->{workflow_id},     'wf-log',      'workflow_id from the start job');
    T2->is($seen->{workflow_run_id}, 'run-log',     'workflow_run_id from the start job');
    T2->is($seen->{workflow_type},   'GreetWorkflow', 'workflow_type from the start job');
});

T2->done_testing;
