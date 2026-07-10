# ABOUTME: Parity test for finding A17 / spec R69 (execute_update divergence):
# ABOUTME: execute_update put wait_for_stage AFTER the caller's %opts, silently
# ABOUTME: clobbering an explicit value with 'completed'. Python's execute_update
# ABOUTME: (client/_workflow.py:792-836) hard-codes COMPLETED and takes no such
# ABOUTME: kwarg; this surface accepts one, so it must honor it, not override.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Scalar::Util ();

use Temporalio::Client ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();

Temporalio::Core::Proto->load;

sub resolve { Temporalio::Core::Proto::resolve($_[0]) }

# Per-object RPC mock registry keyed by client refaddr (the established
# pattern from t/unit/parity_backfills.t / t/unit/client_option_strictness.t).
our %MOCKS;
{
    no warnings 'redefine';
    my $orig = \&Temporalio::Client::_rpc_call;
    *Temporalio::Client::_rpc_call = sub {
        my ($self, $rpc, $request, %opts) = @_;
        if (my $mock = $MOCKS{ Scalar::Util::refaddr($self) }) {
            return $mock->($rpc, $request, %opts);
        }
        return $orig->($self, $rpc, $request, %opts);
    };
}

sub make_client {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-parity',
        identity       => 'id-parity@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# Answer UpdateWorkflowExecution with the requested stage echoed back plus a
# completed success outcome, so start_update's >= ACCEPTED retry loop exits on
# the first response and ->result decodes the known outcome without polling.
# Records every (rpc, request) seen.
sub update_mock ($client, $result_value) {
    my @calls;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request };
        die "unexpected RPC '$rpc' (only UpdateWorkflowExecution expected)\n"
            unless $rpc eq 'UpdateWorkflowExecution';
        my @p = $client->data_converter->to_payloads([$result_value])->get;
        my $payloads = resolve('temporal.api.common.v1.Payloads')
            ->new({ payloads => [@p] });
        my $Resp = resolve(
            'temporal.api.workflowservice.v1.UpdateWorkflowExecutionResponse');
        return Future->done($Resp->new({
            stage   => $request->wait_policy->lifecycle_stage,
            outcome => resolve('temporal.api.update.v1.Outcome')
                ->new({ success => $payloads }),
        }));
    };
    return \@calls;
}

# ---------------------------------------------------------------------------
# The A17 divergence: an explicit wait_for_stage => 'accepted' passed to
# execute_update must reach the UpdateWorkflowExecutionRequest WaitPolicy as
# ACCEPTED (2). The pre-R69 code appended wait_for_stage => 'completed' after
# %opts, so the caller's value was silently overridden to COMPLETED (3).
# ---------------------------------------------------------------------------
T2->subtest('explicit wait_for_stage is honored, not overridden' => sub {
    my $client = make_client;
    my $calls  = update_mock($client, 'upd-result');
    my $h      = $client->get_workflow_handle('wf-parity', run_id => 'run-1');
    my $result = $h->execute_update(
        'my_update', ['arg1'], wait_for_stage => 'accepted')->get;
    T2->is($result, 'upd-result', 'execute_update still returns the result');
    T2->is(scalar(@$calls), 1, 'one RPC');
    T2->is($calls->[0]{rpc}, 'UpdateWorkflowExecution',
        'UpdateWorkflowExecution rpc');
    T2->is($calls->[0]{request}->wait_policy->lifecycle_stage, 2,
        "caller's 'accepted' reaches WaitPolicy as ACCEPTED (2), "
        . 'not overridden to COMPLETED');
});

# ---------------------------------------------------------------------------
# The omitted-kwarg default stays COMPLETED (3): Python's execute_update
# hard-codes WorkflowUpdateStage.COMPLETED (client/_workflow.py:830).
# ---------------------------------------------------------------------------
T2->subtest('omitted wait_for_stage still defaults to completed' => sub {
    my $client = make_client;
    my $calls  = update_mock($client, 'upd-result');
    my $h      = $client->get_workflow_handle('wf-parity', run_id => 'run-1');
    my $result = $h->execute_update('my_update', ['arg1'])->get;
    T2->is($result, 'upd-result', 'execute_update returns the result');
    T2->is($calls->[0]{request}->wait_policy->lifecycle_stage, 3,
        'default wait stage is COMPLETED (3), Python parity');
});

T2->done_testing;
