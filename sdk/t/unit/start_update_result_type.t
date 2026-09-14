# ABOUTME: I8 / GitHub issue #8 acceptance: WorkflowHandle::start_update (and
# ABOUTME: execute_update, which delegates) must accept a result_type decode
# ABOUTME: hint and thread it into the constructed WorkflowUpdateHandle, the
# ABOUTME: way get_update_handle already does (R92), AND that handle must hand
# ABOUTME: the hint to the payload converter on every branch of result().
# ABOUTME: Python parity: WorkflowHandle.start_update / execute_update both take
# ABOUTME: result_type: type | None = None (../sdk-python
# ABOUTME: temporalio/client/_workflow.py:903, :787) and thread it through
# ABOUTME: _start_update (:951, :971) to the WorkflowUpdateHandle it returns,
# ABOUTME: which applies [self._result_type] as decode type_hints (:1929-1932).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
no warnings 'experimental::class';

use Future ();
use Scalar::Util ();

use Temporalio::Client ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Converter::Data ();
use Temporalio::Converter::Payload ();
use Temporalio::Converter::Payload::Json ();
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

# Spy on the ONE construction point for update handles
# (WorkflowHandle::_update_handle) so both start_update's post-RPC handle and
# execute_update's internal handle (execute_update delegates to start_update)
# are observable, not just the one a caller holds directly.
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

# The stock payload converters self-describe and IGNORE the type hint, so a
# client built with Temporalio::Converter::Data->new cannot tell a handle that
# stores result_type from one that drops it on the way to from_payloads: an
# accessor assertion passes either way. This converter records every hint it is
# handed, which is what turns "the handle remembers the type" into "the
# converter was actually told the type" (Python's WorkflowUpdateHandle.result
# passes [self._result_type] as decode type_hints, _workflow.py:1929-1932).
#
# Proven RED against the exact wrong implementation the review predicted:
# with WorkflowUpdateHandle::_decode_all_payloads passing undef instead of
# [$result_type] to from_payloads, the three hint assertions below fail
#   [0] GOT <UNDEF>  CHECK My::ResultType
# once each in subtests 1, 2, and 3, while EVERY pre-existing assertion in
# this file (the result_type accessor and the _update_handle kwargs spy) stays
# green. That is the false pass a hint-blind converter cannot catch.
my $JSON_CONVERTER = Temporalio::Converter::Payload::Json->new;
my @recorded_hints;

class Local::Test::HintRecorder :isa(Temporalio::Converter::Payload) {
    method encoding { $JSON_CONVERTER->encoding }
    method to_payload ($value) { $JSON_CONVERTER->to_payload($value) }

    method from_payload ($payload, $type_hint = undef) {
        push @recorded_hints, $type_hint;
        return $JSON_CONVERTER->from_payload($payload, $type_hint);
    }
}

sub make_client {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-i8',
        identity       => 'id-i8@host',
        data_converter => Temporalio::Converter::Data->new(
            payload_converter => Temporalio::Converter::Payload->new(
                converters => [ Local::Test::HintRecorder->new ]),
        ),
        runtime => undef,
    );
}

sub success_outcome ($client, $result_value) {
    my @p = $client->data_converter->to_payloads([$result_value])->get;
    my $payloads = resolve('temporal.api.common.v1.Payloads')
        ->new({ payloads => [@p] });
    return resolve('temporal.api.update.v1.Outcome')
        ->new({ success => $payloads });
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
        my $Resp = resolve(
            'temporal.api.workflowservice.v1.UpdateWorkflowExecutionResponse');
        return Future->done($Resp->new({
            stage   => $request->wait_policy->lifecycle_stage,
            outcome => success_outcome($client, $result_value),
        }));
    };
    return \@calls;
}

# The other branch of result(): UpdateWorkflowExecution returns ACCEPTED with
# NO outcome, so the handle has no known_outcome and result() reaches
# _poll_until_outcome; PollWorkflowExecutionUpdate then supplies the outcome.
sub polling_mock ($client, $result_value) {
    my @calls;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request };
        if ($rpc eq 'UpdateWorkflowExecution') {
            my $Resp = resolve(
                'temporal.api.workflowservice.v1.UpdateWorkflowExecutionResponse');
            return Future->done($Resp->new({
                stage => $request->wait_policy->lifecycle_stage,
            }));
        }
        if ($rpc eq 'PollWorkflowExecutionUpdate') {
            my $Resp = resolve(
                'temporal.api.workflowservice.v1.PollWorkflowExecutionUpdateResponse');
            return Future->done($Resp->new({
                outcome => success_outcome($client, $result_value),
            }));
        }
        die "unexpected RPC '$rpc' (UpdateWorkflowExecution or "
          . "PollWorkflowExecutionUpdate expected)\n";
    };
    return \@calls;
}

# ---------------------------------------------------------------------------
# start_update(..., result_type => ...) must be accepted (not rejected by the
# R44 strictness validator), must carry the hint on the returned handle, and
# must hand that hint to the payload converter when result() decodes the
# outcome the start RPC already returned.
# ---------------------------------------------------------------------------
T2->subtest('start_update threads result_type onto the returned handle' => sub {
    @update_handle_calls = ();
    @recorded_hints      = ();
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

    T2->is($uh->result->get, 'upd-result', 'result decodes the known outcome');
    T2->is(\@recorded_hints, ['My::ResultType'],
        'the payload converter was handed the result_type as the decode hint');
});

# ---------------------------------------------------------------------------
# execute_update delegates to start_update; its result_type must reach the same
# construction point even though the handle itself is not returned to the
# caller, and must reach the converter on the ->result execute_update makes.
# ---------------------------------------------------------------------------
T2->subtest('execute_update threads result_type through to start_update' => sub {
    @update_handle_calls = ();
    @recorded_hints      = ();
    my $client = make_client;
    update_mock($client, 'upd-result');
    my $h      = $client->get_workflow_handle('wf-i8', run_id => 'run-1');
    my $result = $h->execute_update(
        'my_update', ['arg1'], result_type => 'My::ResultType')->get;
    T2->is($result, 'upd-result', 'execute_update still returns the result');
    T2->is(scalar(@update_handle_calls), 1, 'one handle constructed');
    T2->is($update_handle_calls[0]{result_type}, 'My::ResultType',
        '_update_handle received result_type via execute_update');
    T2->is(\@recorded_hints, ['My::ResultType'],
        'execute_update decodes its result with the result_type hint');
});

# ---------------------------------------------------------------------------
# The polling branch: no outcome on the start response, so result() goes
# through PollWorkflowExecutionUpdate. The hint must survive that path too;
# Python converges both branches on the same decode call by storing the poll
# result in _known_outcome before decoding (_workflow.py:1917-1932).
# ---------------------------------------------------------------------------
T2->subtest('the polling branch decodes with the result_type hint' => sub {
    @update_handle_calls = ();
    @recorded_hints      = ();
    my $client = make_client;
    my $calls  = polling_mock($client, 'polled-result');
    my $h      = $client->get_workflow_handle('wf-i8', run_id => 'run-1');
    my $uh     = $h->start_update(
        'my_update', ['arg1'],
        wait_for_stage => 'accepted', result_type => 'My::ResultType')->get;
    T2->is($uh->result_type, 'My::ResultType',
        'the handle carries the hint with no outcome on the start response');
    T2->is(\@recorded_hints, [],
        'nothing decoded yet: the start response carried no outcome');

    T2->is($uh->result->get, 'polled-result', 'result comes from the poll');
    T2->is([ map { $_->{rpc} } @$calls ],
        [ 'UpdateWorkflowExecution', 'PollWorkflowExecutionUpdate' ],
        'result() reached PollWorkflowExecutionUpdate');
    my $poll = $calls->[1]{request};
    T2->is($poll->update_ref->update_id, $uh->update_id,
        'poll targets the started update');
    T2->is($poll->identity, 'id-i8@host',
        'poll carries the client identity');
    T2->is(\@recorded_hints, ['My::ResultType'],
        'the polled outcome decodes with the result_type hint');
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
