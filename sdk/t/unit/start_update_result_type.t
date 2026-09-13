# ABOUTME: I8 / GitHub issue #8 acceptance: WorkflowHandle::start_update (and
# ABOUTME: execute_update, which delegates) must accept a result_type decode
# ABOUTME: hint and thread it into the constructed WorkflowUpdateHandle, the
# ABOUTME: way get_update_handle already does (R92, WorkflowHandle.pm:577-589).
# ABOUTME: Python parity: WorkflowHandle.start_update / execute_update both take
# ABOUTME: result_type: type | None = None (../sdk-python
# ABOUTME: temporalio/client/_workflow.py:903, :787) and thread it through
# ABOUTME: _start_update (:951, :971) to the WorkflowUpdateHandle it returns.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Scalar::Util ();

use Temporalio::Client ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();

Temporalio::Core::Proto->load;

sub resolve { Temporalio::Core::Proto::resolve($_[0]) }

# Per-object RPC mock registry keyed by client refaddr (established pattern:
# t/unit/parity_execute_update_wait_for_stage.t, t/unit/parity_backfills.t).
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

# Spy on the ONE construction point for update handles (WorkflowHandle.pm
# :595 _update_handle) so both start_update's post-RPC handle and
# execute_update's internal handle (execute_update delegates to start_update,
# WorkflowHandle.pm:475-479) are observable, not just the one a caller holds
# directly.
my @update_handle_calls;
{
    no warnings 'redefine';
    my $orig = \&Temporalio::Client::WorkflowHandle::_update_handle;
    *Temporalio::Client::WorkflowHandle::_update_handle = sub {
        my ($self, $update_id, %fields) = @_;
        push @update_handle_calls, { update_id => $update_id, %fields };
        return $orig->($self, $update_id, %fields);
    };
}

sub make_client {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-i8',
        identity       => 'id-i8@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# Answer UpdateWorkflowExecution with the requested stage echoed back plus a
# completed success outcome, so start_update's >= ACCEPTED retry loop exits on
# the first response and ->result decodes the known outcome without polling.
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
# start_update(..., result_type => ...) must be accepted (not rejected by the
# R44 strictness validator) and must carry the hint on the returned handle.
# ---------------------------------------------------------------------------
T2->subtest('start_update threads result_type onto the returned handle' => sub {
    @update_handle_calls = ();
    my $client = make_client;
    update_mock($client, 'upd-result');
    my $h  = $client->get_workflow_handle('wf-i8', run_id => 'run-1');
    my $uh = $h->start_update(
        'my_update', ['arg1'],
        wait_for_stage => 'accepted', result_type => 'My::ResultType')->get;
    T2->is($uh->result_type, 'My::ResultType',
        'the returned WorkflowUpdateHandle carries the result_type hint');
    T2->is(scalar(@update_handle_calls), 1, 'one handle constructed');
    T2->is($update_handle_calls[0]{result_type}, 'My::ResultType',
        '_update_handle received result_type');
});

# ---------------------------------------------------------------------------
# execute_update delegates to start_update (WorkflowHandle.pm:475-479); its
# result_type must reach the same construction point even though the handle
# itself is not returned to the caller.
# ---------------------------------------------------------------------------
T2->subtest('execute_update threads result_type through to start_update' => sub {
    @update_handle_calls = ();
    my $client = make_client;
    update_mock($client, 'upd-result');
    my $h      = $client->get_workflow_handle('wf-i8', run_id => 'run-1');
    my $result = $h->execute_update(
        'my_update', ['arg1'], result_type => 'My::ResultType')->get;
    T2->is($result, 'upd-result', 'execute_update still returns the result');
    T2->is(scalar(@update_handle_calls), 1, 'one handle constructed');
    T2->is($update_handle_calls[0]{result_type}, 'My::ResultType',
        '_update_handle received result_type via execute_update');
});

# ---------------------------------------------------------------------------
# Strictness (spec R44) holds: adding result_type to the known set must not
# open the door to an arbitrary typo.
# ---------------------------------------------------------------------------
T2->subtest('an unknown option to start_update still raises Argument' => sub {
    my $client = make_client;
    update_mock($client, 'upd-result');
    my $h = $client->get_workflow_handle('wf-i8', run_id => 'run-1');
    my $err = T2->dies(sub {
        $h->start_update(
            'my_update', ['arg1'],
            wait_for_stage => 'accepted', bogus_option => 1)->get;
    });
    T2->like($err, qr/bogus_option/,
        'unknown option name surfaces in the Argument error');
    T2->ok(Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Argument'),
        'unknown option raises Temporalio::Exception::Argument');
});

T2->done_testing;
