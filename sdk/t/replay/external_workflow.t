# ABOUTME: Replay tests for in-workflow external workflow handles (spec section
# ABOUTME: 20): get_external_workflow_handle constructor, SignalExternal /
# ABOUTME: RequestCancelExternal command emission on the workflow_execution arm,
# ABOUTME: Resolve* done/fail mapping, two independent seq spaces, explicit
# ABOUTME: run_id threading, CancelSignalWorkflow on in-flight cancel (T-ext-1..9).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Workflow::Future;
use Temporalio::Converter::Payload;
use Temporalio::Converter::Failure;
use Temporalio::Exception::Application;
use Temporalio::Exception::Workflow::NoRunner;

no warnings 'experimental::class';

# Build a WorkflowActivation proto from the oneof-tagged hashref job form.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;
my $FC = Temporalio::Converter::Failure->default;

sub payload ($value) { return $PC->to_payload($value) }

# An application "not found" Failure proto — the shape a Resolve* job carries
# when the target workflow does not exist.
sub app_failure ($type, $msg) {
    my $cause = Temporalio::Exception::Application->new(message => $msg, type => $type);
    return $FC->to_failure($cause, $PC);
}

# The namespace a Runner reports through info — the worker injects it; the
# replay harness defaults to a fixed value so the workflow_execution arm can be
# asserted. The harness passes namespace through to the Runner.
my $NS = 'replay-ns';

sub harness_for ($class) {
    return Temporalio::Test::WorkflowReplay->new(
        workflow_class => $class,
        namespace      => $NS,
    );
}

# ---------------------------------------------------------------------------
# T-ext-1: get_external_workflow_handle outside a body raises NoRunner; inside a
# body it returns a handle echoing workflow_id/run_id and emits NO command.
# ---------------------------------------------------------------------------
T2->subtest('constructor: NoRunner outside, handle + no command inside (T-ext-1)' => sub {
    my $err = T2->dies(sub {
        Temporalio::Workflow::get_external_workflow_handle('x');
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Workflow::NoRunner'),
        'constructor outside a workflow body raises NoRunner');

    # Inside a body: WfDef::ExternalSignaller resolves a handle but the
    # constructor itself emits nothing — the first (and only) command is the
    # signal. We assert no command is emitted between init and the signal by
    # checking the handle accessors via a dedicated probe workflow would be
    # heavier; instead T-ext-2 below proves the single signal command. Here we
    # confirm the handle is constructed without dying and the run parks on the
    # signal await (one command, the signal — not a constructor command).
    my $h = harness_for('WfDef::ExternalSignaller');
    my @commands = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalSignaller' } },
        ],
    }));
    T2->is(scalar @commands, 1,
        'constructor emits no command; only the signal command appears');
    T2->is($commands[0]->which_variant, 'signal_external_workflow_execution',
        'the sole command is the signal, not a constructor command');
});

# ---------------------------------------------------------------------------
# T-ext-2: await $h->signal('go', args=>['x']) emits one
# SignalExternalWorkflowExecution (seq 1, workflow_execution arm: namespace =
# run's namespace, workflow_id = handle id, run_id empty when undef;
# signal_name='go'; encoded args). child_workflow_id arm unset.
# ---------------------------------------------------------------------------
T2->subtest('signal emits SignalExternalWorkflowExecution on workflow_execution arm (T-ext-2)' => sub {
    my $h = harness_for('WfDef::ExternalSignaller');
    my @commands = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalSignaller' } },
        ],
    }));

    T2->is(scalar @commands, 1, 'one command emitted');
    my $cmd = $commands[0];
    T2->is($cmd->which_variant, 'signal_external_workflow_execution',
        'the command is SignalExternalWorkflowExecution');

    my $s = $cmd->signal_external_workflow_execution;
    T2->is($s->seq, 1, 'external-signal seq starts at 1');
    T2->is($s->which_target, 'workflow_execution',
        'the workflow_execution oneof arm is set (not child_workflow_id)');

    my $we = $s->workflow_execution;
    T2->is($we->namespace, $NS, 'namespace is the running workflow namespace');
    T2->is($we->workflow_id, 'other-wf', 'workflow_id is the handle id');
    T2->is($we->run_id, '', 'run_id empty when undef');

    T2->is($s->signal_name, 'go', 'signal_name is the supplied name');
    T2->is(scalar $s->args->@*, 1, 'one arg payload');
    T2->is($PC->from_payload($s->args->[0]), 'x', 'arg round-trips');
});

# ---------------------------------------------------------------------------
# T-ext-3: ResolveSignalExternalWorkflow{seq 1} (no failure) resolves the signal
# future done; the run then completes.
# ---------------------------------------------------------------------------
T2->subtest('ResolveSignalExternalWorkflow without failure resolves done (T-ext-3)' => sub {
    my $h = harness_for('WfDef::ExternalSignaller');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalSignaller' } },
        ],
    }));

    my @second = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_signal_external_workflow => { seq => 1 } },
        ],
    }));
    T2->is(scalar @second, 1, 'one command after the signal resolves');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'the run completes once the signal is acknowledged');
    T2->is($PC->from_payload($second[0]->complete_workflow_execution->result),
        'other-wf', 'completion carries the handle workflow_id');
});

# ---------------------------------------------------------------------------
# T-ext-4: ResolveSignalExternalWorkflow with an application "not found" failure
# raises Exception::Application at the await site (message/type round-trip), and
# the run fails.
# ---------------------------------------------------------------------------
T2->subtest('ResolveSignalExternalWorkflow with failure raises Application (T-ext-4)' => sub {
    my $h = harness_for('WfDef::ExternalSignaller');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalSignaller' } },
        ],
    }));

    my $completion = $h->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_signal_external_workflow => {
                seq     => 1,
                failure => app_failure('NotFound', 'workflow not found'),
            } },
        ],
    }));
    my @cmds = $h->commands_of($completion);
    T2->is(scalar @cmds, 1, 'one command after a failed signal resolve');
    T2->is($cmds[0]->which_variant, 'fail_workflow_execution',
        'the unhandled Application fails the workflow');
    my $f = $cmds[0]->fail_workflow_execution->failure;
    T2->like($f->message, qr/workflow not found/,
        'the failure message round-trips from the resolve failure');
});

# ---------------------------------------------------------------------------
# T-ext-5: await $h->cancel emits one RequestCancelExternalWorkflowExecution
# (seq 1, same workflow_execution, reason unset).
# ---------------------------------------------------------------------------
T2->subtest('cancel emits RequestCancelExternalWorkflowExecution (T-ext-5)' => sub {
    my $h = harness_for('WfDef::ExternalCanceller');
    my @commands = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalCanceller' } },
        ],
    }));

    T2->is(scalar @commands, 1, 'one command emitted');
    my $cmd = $commands[0];
    T2->is($cmd->which_variant, 'request_cancel_external_workflow_execution',
        'the command is RequestCancelExternalWorkflowExecution');

    my $c = $cmd->request_cancel_external_workflow_execution;
    T2->is($c->seq, 1, 'external-cancel seq starts at 1 (its own space)');
    my $we = $c->workflow_execution;
    T2->is($we->namespace, $NS, 'namespace is the running workflow namespace');
    T2->is($we->workflow_id, 'other-wf', 'workflow_id is the handle id');
    T2->is($we->run_id, '', 'run_id empty when undef');
    T2->is($c->reason, '', 'reason unset');
});

# ---------------------------------------------------------------------------
# T-ext-6: ResolveRequestCancelExternalWorkflow{seq 1} resolves done; a failure
# raises Application.
# ---------------------------------------------------------------------------
T2->subtest('ResolveRequestCancelExternalWorkflow done / failure->Application (T-ext-6)' => sub {
    # done path.
    my $h = harness_for('WfDef::ExternalCanceller');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalCanceller' } },
        ],
    }));
    my @second = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_request_cancel_external_workflow => { seq => 1 } },
        ],
    }));
    T2->is(scalar @second, 1, 'one command after the cancel resolves');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'the run completes once the cancel request is acknowledged');

    # failure path.
    my $h2 = harness_for('WfDef::ExternalCanceller');
    $h2->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalCanceller' } },
        ],
    }));
    my $completion = $h2->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_request_cancel_external_workflow => {
                seq     => 1,
                failure => app_failure('NotFound', 'no such workflow'),
            } },
        ],
    }));
    my @cmds = $h2->commands_of($completion);
    T2->is(scalar @cmds, 1, 'one command after a failed cancel resolve');
    T2->is($cmds[0]->which_variant, 'fail_workflow_execution',
        'a failed cancel request fails the workflow via the unhandled Application');
});

# ---------------------------------------------------------------------------
# T-ext-7: independent seq spaces — two signals then a cancel emit signals seq
# 1,2 and cancel seq 1; out-of-order resolves settle the right futures.
# ---------------------------------------------------------------------------
T2->subtest('independent signal/cancel seq spaces, out-of-order resolve (T-ext-7)' => sub {
    my $h = harness_for('WfDef::ExternalSeqSpaces');
    my @commands = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalSeqSpaces' } },
        ],
    }));

    T2->is(scalar @commands, 3, 'three commands: two signals and one cancel');
    my @signals = grep {
        $_->which_variant eq 'signal_external_workflow_execution'
    } @commands;
    my @cancels = grep {
        $_->which_variant eq 'request_cancel_external_workflow_execution'
    } @commands;
    T2->is(scalar @signals, 2, 'two signal commands');
    T2->is(scalar @cancels, 1, 'one cancel command');
    T2->is(
        [ sort map { $_->signal_external_workflow_execution->seq } @signals ],
        [ 1, 2 ],
        'signals take seq 1 and 2 in the external-signal space');
    T2->is($cancels[0]->request_cancel_external_workflow_execution->seq, 1,
        'cancel takes seq 1 in its own external-cancel space');

    # Out-of-order resolution: cancel first, then signal 2, then signal 1 — the
    # run only completes once all three are settled.
    my @r1 = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_request_cancel_external_workflow => { seq => 1 } } ],
    }));
    T2->is(scalar @r1, 0, 'no completion yet (two signals still pending)');

    my @r2 = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { resolve_signal_external_workflow => { seq => 2 } } ],
    }));
    T2->is(scalar @r2, 0, 'no completion yet (signal 1 still pending)');

    my @r3 = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 103 },
        jobs   => [ { resolve_signal_external_workflow => { seq => 1 } } ],
    }));
    T2->is(scalar @r3, 1, 'run completes once all three resolve');
    T2->is($r3[0]->which_variant, 'complete_workflow_execution',
        'completion after the last resolve');
});

# ---------------------------------------------------------------------------
# T-ext-8: explicit run_id threads into NamespacedWorkflowExecution.run_id for
# both the signal and the cancel commands.
# ---------------------------------------------------------------------------
T2->subtest('explicit run_id threads into both commands (T-ext-8)' => sub {
    my $h = harness_for('WfDef::ExternalRunId');
    my @commands = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalRunId' } },
        ],
    }));

    T2->is(scalar @commands, 2, 'two commands: signal and cancel');
    my ($sig) = grep {
        $_->which_variant eq 'signal_external_workflow_execution'
    } @commands;
    my ($can) = grep {
        $_->which_variant eq 'request_cancel_external_workflow_execution'
    } @commands;
    T2->is($sig->signal_external_workflow_execution->workflow_execution->run_id,
        'run-abc', 'signal carries the explicit run_id');
    T2->is($can->request_cancel_external_workflow_execution->workflow_execution->run_id,
        'run-abc', 'cancel carries the explicit run_id');
});

# ---------------------------------------------------------------------------
# T-ext-9: cancelling an in-flight signal's frame emits CancelSignalWorkflow{seq}
# (does NOT pre-emptively raise); a subsequent ResolveSignalExternalWorkflow
# settles the future.
# ---------------------------------------------------------------------------
T2->subtest('in-flight signal cancel emits CancelSignalWorkflow (T-ext-9)' => sub {
    my $h = harness_for('WfDef::ExternalSignalCanceller');
    my @commands = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ExternalSignalCanceller' } },
        ],
    }));

    # The signal (seq 1) and the CancelSignalWorkflow{seq 1} are both emitted in
    # the init activation; the body then parks (does not complete or fail).
    my ($sig) = grep {
        $_->which_variant eq 'signal_external_workflow_execution'
    } @commands;
    my ($cancel_sig) = grep {
        $_->which_variant eq 'cancel_signal_workflow'
    } @commands;
    T2->ok(defined $sig, 'the signal command is emitted');
    T2->ok(defined $cancel_sig, 'a CancelSignalWorkflow command is emitted');
    T2->is($cancel_sig->cancel_signal_workflow->seq,
        $sig->signal_external_workflow_execution->seq,
        'CancelSignalWorkflow targets the same seq as the signal');

    # No fail/complete in this activation — cancelling the frame does not
    # pre-emptively settle the run.
    my @terminal = grep {
        $_->which_variant eq 'complete_workflow_execution'
            || $_->which_variant eq 'fail_workflow_execution'
            || $_->which_variant eq 'cancel_workflow_execution'
    } @commands;
    T2->is(scalar @terminal, 0,
        'the in-flight cancel does not pre-emptively complete or fail the run');

    # A later resolve settles the underlying future without error.
    my @second = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 101 },
        jobs   => [ { resolve_signal_external_workflow => { seq => 1 } } ],
    }));
    T2->is(scalar @second, 0,
        'resolving the cancelled signal does not crash or complete the parked run');
});

T2->done_testing;
