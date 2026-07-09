# ABOUTME: Unit tests for invoking the worker INBOUND interceptor chains (#10
# ABOUTME: C-ICEPT): the activity dispatcher and the workflow Runner must route
# ABOUTME: execute_activity / execute_workflow / handle_signal / handle_query /
# ABOUTME: handle_update through the built chain (client then worker, outermost
# ABOUTME: first) to the real impl, not bypass it.
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

use Temporalio::Converter::Data ();
use Temporalio::Converter::Payload ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::ActivityRegistry ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::Interceptor ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Test::WorkflowReplay ();

# --------------------------------------------------------------------------
# Spy interceptor fixtures. Each inbound spy records "<tag>:<method>" onto a
# shared trace, then delegates to the next link — so the trace is the exact
# order the inbound chain was actually invoked. Signature-less methods and the
# T2-> call form below are required under `feature 'class'` + Future::AsyncAwait
# (see t/unit/interceptors.t).
# --------------------------------------------------------------------------
class SpyActivityInbound :isa(Temporalio::Worker::ActivityInbound) {
    field $tag   :param;
    field $trace :param;
    method execute_activity {
        push @$trace, "$tag:execute_activity";
        return $self->next->execute_activity($_[0]);
    }
}
class SpyWorkflowInbound :isa(Temporalio::Worker::WorkflowInbound) {
    field $tag   :param;
    field $trace :param;
    method execute_workflow {
        push @$trace, "$tag:execute_workflow";
        return $self->next->execute_workflow($_[0]);
    }
    method handle_signal {
        push @$trace, "$tag:handle_signal";
        return $self->next->handle_signal($_[0]);
    }
    method handle_query {
        push @$trace, "$tag:handle_query";
        return $self->next->handle_query($_[0]);
    }
    method handle_update {
        push @$trace, "$tag:handle_update";
        return $self->next->handle_update($_[0]);
    }
}
class SpyInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $tag   :param;
    field $trace :param;
    method intercept_activity {
        return SpyActivityInbound->new(next => $_[0], tag => $tag, trace => $trace);
    }
    method intercept_workflow {
        return SpyWorkflowInbound->new(next => $_[0], tag => $tag, trace => $trace);
    }
}

# A minimal data converter + fake client (mirrors t/unit/activity_dispatch.t).
class FakeClient {
    field $data_converter :param;
    field $namespace      :param = 'default';
    field $identity       :param = 'pid@host';
    method data_converter { $data_converter }
    method namespace      { $namespace }
    method identity       { $identity }
}

my $loop = IO::Async::Loop->new;
sub await_f ($f) { return $f->get }

my $ActivityTask = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityTask');
my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
my $WorkflowExecution = Temporalio::Core::Proto::resolve(
    'temporal.api.common.v1.WorkflowExecution');

sub start_task_bytes ($dc, $token, $type, @args) {
    my @payloads = await_f($dc->to_payloads([@args]));
    my $start = $Start->new({
        workflow_namespace => 'default',
        workflow_type      => 'GreetWorkflow',
        workflow_execution => $WorkflowExecution->new({
            workflow_id => 'wf-1', run_id => 'run-1' }),
        activity_id   => 'act-1',
        activity_type => $type,
        input         => [@payloads],
        attempt       => 1,
    });
    return $ActivityTask->new({ task_token => $token, start => $start })->encode;
}

# --------------------------------------------------------------------------
# Activity dispatcher: the activity-inbound chain is invoked (client then
# worker, outermost first) and execution still reaches the real body (#10).
# --------------------------------------------------------------------------
T2->subtest('activity dispatch routes through the inbound chain in order' => sub {
    my @trace;
    my $dc = Temporalio::Converter::Data->new;
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'greet',
        code => async sub ($name) { return "Hi, $name" },
    );
    my $registry =
        Temporalio::Worker::ActivityRegistry->new(activities => [$fn]);
    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        client         => FakeClient->new(data_converter => $dc),
        loop           => $loop,
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
        # Client-supplied (A) then worker-supplied (B): A is outermost.
        interceptors   => [
            SpyInterceptor->new(tag => 'A', trace => \@trace),
            SpyInterceptor->new(tag => 'B', trace => \@trace),
        ],
    );

    await_f($dispatcher->dispatch_task(
        start_task_bytes($dc, 'tok-1', 'greet', 'World')));

    T2->is(\@trace, [ 'A:execute_activity', 'B:execute_activity' ],
        'A (client, outermost) ran before B (worker), both reached');
    T2->is(scalar(@completions), 1,
        'the activity still completed (execution reached the real body)');
});

# --------------------------------------------------------------------------
# Workflow Runner: one activation with init + signal + update + query routes
# execute_workflow / handle_signal / handle_update / handle_query through the
# chain (#10), and the real handlers still run (update result + query response).
# --------------------------------------------------------------------------
T2->subtest('workflow activation routes every inbound method through the chain' => sub {
    my @trace;
    my $PC = Temporalio::Converter::Payload->default;
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::InterceptorObserved',
        interceptors   => [
            SpyInterceptor->new(tag => 'A', trace => \@trace),
            SpyInterceptor->new(tag => 'B', trace => \@trace),
        ],
    );

    my $activation =
        'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    my @cmds = $harness->push_activation($activation->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'InterceptorObserved',
                arguments     => [],
            } },
            { signal_workflow => {
                signal_name => 'poke',
                input       => [ $PC->to_payload('x') ],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-1',
                name                 => 'add',
                input                => [ $PC->to_payload(5) ],
                run_validator        => 1,
            } },
            { query_workflow => {
                query_id   => 'q-1',
                query_type => 'total',
                arguments  => [],
            } },
        ],
    }));

    # Signal and update hooks fire BEFORE execute_workflow: init-activation
    # signals and updates are applied before the main routine starts (spec R26
    # signals-before-main, matching sdk-python's set 1 before set 2); queries
    # are always last (set 3).
    T2->is(\@trace, [
        'A:handle_signal',    'B:handle_signal',
        'A:handle_update',    'B:handle_update',
        'A:execute_workflow', 'B:execute_workflow',
        'A:handle_query',     'B:handle_query',
    ], 'every inbound method invoked, outermost (client) first then worker');

    # The real handlers still ran THROUGH the chain: the update completed with
    # the mutated total and the query observed that same state.
    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    my ($completed) = grep { $_->update_response->which_response eq 'completed' } @ur;
    T2->ok(defined $completed, 'the update reached the real handler (completed)');
    T2->is($PC->from_payload($completed->update_response->completed), 5,
        'update handler returned the mutated total through the chain');

    my ($query) = grep { $_->which_variant eq 'respond_to_query' } @cmds;
    T2->ok(defined $query, 'the query reached the real handler');
    T2->is($query->respond_to_query->which_variant, 'succeeded',
        'the query succeeded');
    T2->is($PC->from_payload($query->respond_to_query->succeeded->response), 5,
        'query observed the state the update mutated through the chain');
});

T2->done_testing;
