# ABOUTME: Replay tests for the workflow-OUTBOUND interceptor chain (spec R71,
# ABOUTME: parity finding 1): an outbound wrapper installed via WorkflowInbound
# ABOUTME: init(outbound) must observe execute_activity / start_child_workflow,
# ABOUTME: and its arg/header mutations must reach the emitted command.
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto ();
use Temporalio::Converter::Payload ();
use Temporalio::Test::WorkflowReplay ();
use Temporalio::Worker::Interceptor ();

# ---------------------------------------------------------------------------
# Fixtures. The install mechanism under test is Python's
# (_workflow_instance.py:392-398): the Runner folds the inbound chain, calls
# inbound->init(root outbound), and each interceptor inbound may WRAP the
# outbound it receives before delegating init down-chain; whatever reaches the
# root inbound is the chain the outbound operations route through. Classes are
# declared before any signatured helper sub (F::AA parser rule, lessons.md
# 2026-07-09), methods are signature-less, and Test2 helpers use the T2-> form.
# ---------------------------------------------------------------------------

# The outbound wrapper: tags each observed call onto the shared trace, prefixes
# every arg with "[$tag]", injects an x-icept-$tag header on activity starts,
# then delegates to the next outbound link.
class TaggingOutbound :isa(Temporalio::Worker::WorkflowOutbound) {
    field $tag   :param;
    field $trace :param;
    method execute_activity {
        push @$trace, "$tag:execute_activity";
        $_[0]->args([ map { "[$tag]$_" } @{ $_[0]->args } ]);
        $_[0]->headers({ %{ $_[0]->headers }, "x-icept-$tag" => "seen-$tag" });
        return $self->next->execute_activity($_[0]);
    }
    method start_child_workflow {
        push @$trace, "$tag:start_child_workflow";
        $_[0]->args([ map { "[$tag]$_" } @{ $_[0]->args } ]);
        return $self->next->start_child_workflow($_[0]);
    }
}

# The inbound whose init wraps the received outbound (Python
# _TracingWorkflowInboundInterceptor.init parity) before delegating.
class WrappingInbound :isa(Temporalio::Worker::WorkflowInbound) {
    field $tag   :param;
    field $trace :param;
    method init {
        return $self->next->init(TaggingOutbound->new(
            next => $_[0], tag => $tag, trace => $trace));
    }
}

class OutboundInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $tag   :param;
    field $trace :param;
    method intercept_workflow {
        return WrappingInbound->new(next => $_[0], tag => $tag, trace => $trace);
    }
}

# --- helpers ----------------------------------------------------------------

my $PC = Temporalio::Converter::Payload->default;

sub activation ($jobs) {
    return 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation'
        ->new({ run_id => 'r1', timestamp => { seconds => 100 }, jobs => $jobs });
}

sub init_job ($type, @args) {
    return { initialize_workflow => {
        workflow_type => $type,
        arguments     => [ map { $PC->to_payload($_) } @args ],
    } };
}

# ---------------------------------------------------------------------------
# An outbound execute_activity interceptor's arg/header mutations reach the
# emitted ScheduleActivity command (spec R71 acceptance criterion; fails
# against the unwired base, where the wrapper is never invoked).
# ---------------------------------------------------------------------------
T2->subtest('outbound execute_activity mutation reaches ScheduleActivity' => sub {
    my @trace;
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCaller',
        interceptors   =>
            [ OutboundInterceptor->new(tag => 'A', trace => \@trace) ],
    );

    my @commands = $harness->push_activation(
        activation([ init_job('ActivityCaller', 'Alice') ]));

    T2->is(scalar @commands, 1, 'one command emitted');
    T2->is($commands[0]->which_variant, 'schedule_activity',
        'the command is ScheduleActivity');
    my $sa = $commands[0]->schedule_activity;
    T2->is($PC->from_payload($sa->arguments->[0]), '[A]Alice',
        'the outbound arg mutation reached the command');
    T2->is($PC->from_payload(($sa->headers // {})->{'x-icept-A'}), 'seen-A',
        'the outbound header injection reached the command');
    T2->is(\@trace, ['A:execute_activity'],
        'the outbound wrapper observed the call');
});

# ---------------------------------------------------------------------------
# An outbound start_child_workflow interceptor's arg mutation reaches the
# emitted StartChildWorkflowExecution command.
# ---------------------------------------------------------------------------
T2->subtest('outbound start_child_workflow mutation reaches the command' => sub {
    my @trace;
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ChildStarter',
        interceptors   =>
            [ OutboundInterceptor->new(tag => 'A', trace => \@trace) ],
    );

    my @commands = $harness->push_activation(
        activation([ init_job('ChildStarter') ]));

    T2->is(scalar @commands, 1, 'one command emitted');
    T2->is($commands[0]->which_variant, 'start_child_workflow_execution',
        'the command is StartChildWorkflowExecution');
    my $sc = $commands[0]->start_child_workflow_execution;
    T2->is($PC->from_payload($sc->input->[0]), '[A]Bob',
        'the outbound arg mutation reached the command');
    T2->is(\@trace, ['A:start_child_workflow'],
        'the outbound wrapper observed the call');
});

# ---------------------------------------------------------------------------
# The base outbound (no interceptors) emits the un-mutated command: the chain
# root alone must not change behavior.
# ---------------------------------------------------------------------------
T2->subtest('base outbound (no interceptors) emits the un-mutated command' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCaller',
    );

    my @commands = $harness->push_activation(
        activation([ init_job('ActivityCaller', 'Alice') ]));

    T2->is(scalar @commands, 1, 'one command emitted');
    my $sa = $commands[0]->schedule_activity;
    T2->is($PC->from_payload($sa->arguments->[0]), 'Alice',
        'the argument is unchanged');
    T2->ok(!(($sa->headers // {})->{'x-icept-A'}),
        'no interceptor header was injected');
});

# ---------------------------------------------------------------------------
# Wrapping order (Python parity, _workflow_instance.py:392-398): init flows
# outermost-inbound-first, and each wrapper wraps what it RECEIVES, so the
# FIRST-listed interceptor's outbound wrapper sits INNERMOST on the outbound
# side, and the LAST-listed wrapper runs first on every outbound call.
# ---------------------------------------------------------------------------
T2->subtest('outbound wrapping order matches Python init semantics' => sub {
    my @trace;
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCaller',
        interceptors   => [
            OutboundInterceptor->new(tag => 'A', trace => \@trace),
            OutboundInterceptor->new(tag => 'B', trace => \@trace),
        ],
    );

    my @commands = $harness->push_activation(
        activation([ init_job('ActivityCaller', 'Alice') ]));

    T2->is(\@trace, [ 'B:execute_activity', 'A:execute_activity' ],
        'last-listed wrapper (B) ran first (it wrapped what A had wrapped)');
    my $sa = $commands[0]->schedule_activity;
    T2->is($PC->from_payload($sa->arguments->[0]), '[A][B]Alice',
        'mutations applied B-then-A, innermost-last');
});

T2->done_testing;
