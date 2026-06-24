# ABOUTME: Unit tests for eager start (spec section 23, P7.3): request_eager_start
# ABOUTME: -> request_eager_execution on the wire (T-eager-1), WorkflowHandle
# ABOUTME: eagerly_started off the start response (T-eager-2/3), no_remote_activities
# ABOUTME: -> bridge enable_remote_activities=0 (T-eager-4), and
# ABOUTME: disable_eager_activity_execution suppressing the schedule_activity eager
# ABOUTME: flag (T-eager-6).
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Scalar::Util ();
use Temporalio::Client ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Converter::Data ();
use Temporalio::Converter::Payload ();
use Temporalio::Core::FFI ();
use Temporalio::Core::Proto ();
use Temporalio::Test::WorkflowReplay ();
use Temporalio::Worker ();
use Temporalio::Activity::FunctionDefinition ();

Temporalio::Core::Proto->load;

# ---------------------------------------------------------------------------
# T-eager-1: request_eager_start => 1 sets request_eager_execution on the
# StartWorkflowExecutionRequest. The default (omitted) leaves it false.
# ---------------------------------------------------------------------------
sub make_client (%override) {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => $override{namespace} // 'ns-test',
        identity       => $override{identity}  // 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

T2->subtest('request_eager_start sets request_eager_execution (T-eager-1)' => sub {
    my $client = make_client;

    my $on = $client->_build_start_workflow_request(
        'MyWorkflow', [],
        id => 'wf-1', task_queue => 'demo', request_eager_start => 1,
    )->get;
    T2->ok($on->request_eager_execution,
        'request_eager_start => 1 sets request_eager_execution');

    my $off = $client->_build_start_workflow_request(
        'MyWorkflow', [],
        id => 'wf-2', task_queue => 'demo',
    )->get;
    T2->ok(!$off->request_eager_execution,
        'request_eager_execution is false by default');
});

# ---------------------------------------------------------------------------
# T-eager-2 / T-eager-3: WorkflowHandle->eagerly_started reflects whether the
# StartWorkflowExecutionResponse carried an eager_workflow_task. start_workflow
# sets it from the response; a directly-built handle defaults to false.
# ---------------------------------------------------------------------------
T2->subtest('WorkflowHandle->eagerly_started off the response (T-eager-2/3)' => sub {
    my $with_task = Temporalio::Client::WorkflowHandle->new(
        client          => undef,
        workflow_id     => 'wf-1',
        run_id          => 'r1',
        eagerly_started => 1,
    );
    T2->ok($with_task->eagerly_started,
        'eagerly_started true when an eager task was returned (T-eager-2)');

    my $without = Temporalio::Client::WorkflowHandle->new(
        client      => undef,
        workflow_id => 'wf-2',
        run_id      => 'r2',
    );
    T2->ok(!$without->eagerly_started,
        'eagerly_started false by default (T-eager-3)');
});

# start_workflow threads the response's eager_workflow_task presence into the
# handle. Drive it with a mocked _rpc_call so no server is needed.
T2->subtest('start_workflow sets eagerly_started from the response' => sub {
    my $Response = Temporalio::Core::Proto::resolve(
        'temporal.api.workflowservice.v1.StartWorkflowExecutionResponse');
    my $PollResp = Temporalio::Core::Proto::resolve(
        'temporal.api.workflowservice.v1.PollWorkflowTaskQueueResponse');

    # A response WITH an eager_workflow_task.
    {
        my $client = make_client;
        no warnings 'redefine';
        local *Temporalio::Client::_rpc_call = sub ($self, $rpc, $req, %o) {
            return Future->done($Response->new({
                run_id            => 'run-eager',
                eager_workflow_task => $PollResp->new({}),
            }));
        };
        my $handle = $client->start_workflow(
            'MyWorkflow', [], id => 'wf-e', task_queue => 'demo')->get;
        T2->ok($handle->eagerly_started,
            'eager_workflow_task present -> eagerly_started true');
    }

    # A response WITHOUT one.
    {
        my $client = make_client;
        no warnings 'redefine';
        local *Temporalio::Client::_rpc_call = sub ($self, $rpc, $req, %o) {
            return Future->done($Response->new({ run_id => 'run-plain' }));
        };
        my $handle = $client->start_workflow(
            'MyWorkflow', [], id => 'wf-p', task_queue => 'demo')->get;
        T2->ok(!$handle->eagerly_started,
            'no eager_workflow_task -> eagerly_started false');
    }
});

# ---------------------------------------------------------------------------
# T-eager-4: no_remote_activities => 1 sets the bridge WorkerOptions field
# enable_remote_activities = 0. Verified via the P0.10 debug echo path.
# ---------------------------------------------------------------------------
class FakeClient {
    field $namespace :param = 'default';
    field $identity  :param = 'pid@host';
    method namespace { $namespace }
    method identity  { $identity }
}

sub echo_options ($ptr) {
    my $raw = Temporalio::Core::FFI::debug_worker_options($ptr);
    defined $raw or T2->bail_out('debug_worker_options returned NULL');
    my $summary = Temporalio::Core::FFI::ffi()->cast('opaque' => 'string', $raw);
    Temporalio::Core::FFI::string_free($raw);
    return {
        map { my ($k, $v) = split /=/, $_, 2; ($k => $v) }
        split /\n/, $summary,
    };
}

T2->subtest('no_remote_activities -> enable_remote_activities=0 (T-eager-4)' => sub {
    my $activity = Temporalio::Activity::FunctionDefinition->new(
        name => 'a', code => sub { });

    my $default = Temporalio::Worker->new(
        client => FakeClient->new, task_queue => 'tq', activities => [$activity]);
    my $keep0 = [];
    my $echo0 = echo_options($default->_build_worker_options($keep0));
    T2->is($echo0->{'task_types.enable_remote_activities'}, 'true',
        'default worker enables remote activities');

    my $no_remote = Temporalio::Worker->new(
        client => FakeClient->new, task_queue => 'tq', activities => [$activity],
        no_remote_activities => 1);
    my $keep1 = [];
    my $echo1 = echo_options($no_remote->_build_worker_options($keep1));
    T2->is($echo1->{'task_types.enable_remote_activities'}, 'false',
        'no_remote_activities => 1 disables remote activities (T-eager-4)');
});

# ---------------------------------------------------------------------------
# T-eager-6: disable_eager_activity_execution => 1 sets do_not_eagerly_execute
# on the emitted ScheduleActivity command. Default (0) leaves it false.
# The flag is worker-side and threads worker -> WorkflowDispatcher -> Runner ->
# schedule_activity; the replay harness exposes it as a constructor kwarg.
# ---------------------------------------------------------------------------
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub schedule_activity_of ($harness) {
    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ActivityCaller',
                arguments     => [ $PC->to_payload('Alice') ],
            } },
        ],
    }));
    my ($sa) = grep { $_->which_variant eq 'schedule_activity' } @commands;
    return $sa ? $sa->schedule_activity : undef;
}

T2->subtest('disable_eager_activity_execution -> do_not_eagerly_execute (T-eager-6)' => sub {
    my $default = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCaller');
    my $sa0 = schedule_activity_of($default);
    T2->ok(defined $sa0, 'default harness emits a ScheduleActivity');
    T2->ok(!$sa0->do_not_eagerly_execute,
        'do_not_eagerly_execute is false by default');

    my $disabled = Temporalio::Test::WorkflowReplay->new(
        workflow_class                  => 'WfDef::ActivityCaller',
        disable_eager_activity_execution => 1);
    my $sa1 = schedule_activity_of($disabled);
    T2->ok(defined $sa1, 'disabled harness emits a ScheduleActivity');
    T2->ok($sa1->do_not_eagerly_execute,
        'disable_eager_activity_execution => 1 sets do_not_eagerly_execute (T-eager-6)');
});

T2->done_testing;
