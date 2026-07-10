# ABOUTME: Replay tests for runtime signal/query/update handler registration
# ABOUTME: (spec R86; parity audit, in-workflow finding 4): set_*_handler installs
# ABOUTME: named and dynamic handlers on the running instance with buffered-signal
# ABOUTME: drain-on-registration, get_*_handler returns the installed coderef, and
# ABOUTME: undef unsets — MUST-match sdk-python workflow/_workflow_ops.py:833-985.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Converter::Payload;

no warnings 'experimental::class';

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# ---------------------------------------------------------------------------
# A runtime-set NAMED signal handler runs, and a signal that arrived BEFORE
# registration (buffered) drains and runs ON registration (Python
# set_signal_handler: "all unhandled past signals for the given name are
# immediately sent to the handler").
# ---------------------------------------------------------------------------
T2->subtest('runtime named signal handler runs; buffered signal drains on registration' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::RuntimeHandlerRegistrar',
    );

    # Init: the body parks on its timer; no handler for 'runtime_sig' yet.
    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'RuntimeHandlerRegistrar',
                arguments     => [],
            } },
        ],
    }));
    T2->is(scalar @init, 1, 'init activation emits only the parked timer');
    T2->is($init[0]->which_variant, 'start_timer', 'the body parked on a timer');

    # A signal BEFORE registration: no handler exists, so it buffers.
    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'runtime_sig',
                input       => [ payload('early') ],
            } },
        ],
    }));
    T2->is($harness->runner->_buffered_signal_names, ['runtime_sig'],
        'the pre-registration signal is buffered');

    # Fire the timer: the body registers the runtime handler, which must drain
    # the buffered signal immediately.
    my @after_register = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 160 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));
    T2->ok(!(grep { $_->which_variant eq 'fail_workflow_execution' } @after_register),
        'registering the runtime handler did not fail the workflow');
    T2->is($harness->runner->_buffered_signal_names, [],
        'registration drained the buffered signal');

    # A signal AFTER registration dispatches straight to the runtime handler.
    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 170 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'runtime_sig',
                input       => [ payload('late') ],
            } },
        ],
    }));

    my @done = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 180 },
        jobs      => [
            { signal_workflow => { signal_name => 'finish', input => [] } },
        ],
    }));
    my ($complete) =
        grep { $_->which_variant eq 'complete_workflow_execution' } @done;
    T2->ok($complete, 'the workflow completes');
    T2->is($PC->from_payload($complete->complete_workflow_execution->result),
        'runtime_sig=early,runtime_sig=late',
        'the runtime handler received the buffered signal then the live one, in order');
});

# ---------------------------------------------------------------------------
# A runtime-set DYNAMIC signal handler drains EVERY buffered signal in arrival
# order on registration (Python set_signal_handler with name None).
# ---------------------------------------------------------------------------
T2->subtest('runtime dynamic signal handler drains all buffered signals in order' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::RuntimeDynamicRegistrar',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'RuntimeDynamicRegistrar',
                arguments     => [],
            } },
        ],
    }));

    # Two signals under names with no handler: both buffer, in arrival order.
    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'alpha',
                input       => [ payload(1) ],
            } },
            { signal_workflow => {
                signal_name => 'beta',
                input       => [ payload(2) ],
            } },
        ],
    }));
    T2->is($harness->runner->_buffered_signal_names, [ 'alpha', 'beta' ],
        'both unhandled signals are buffered');

    # Fire the timer: the body registers the dynamic catch-all, draining both.
    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 160 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));
    T2->is($harness->runner->_buffered_signal_names, [],
        'dynamic registration drained the whole buffer');

    my @done = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 170 },
        jobs      => [
            { signal_workflow => { signal_name => 'finish', input => [] } },
        ],
    }));
    my ($complete) =
        grep { $_->which_variant eq 'complete_workflow_execution' } @done;
    T2->ok($complete, 'the workflow completes');
    T2->is($PC->from_payload($complete->complete_workflow_execution->result),
        'alpha=1,beta=2',
        'the dynamic handler received both buffered signals in arrival order');
});

# ---------------------------------------------------------------------------
# Edge: get_*_handler returns the installed coderef (and sees compile-time
# attribute handlers through the same lookup), setting undef removes it, and a
# runtime query handler + runtime update handler (with validator) actually
# dispatch QueryWorkflow / DoUpdate jobs.
# ---------------------------------------------------------------------------
T2->subtest('getters return installed handlers; undef unsets; runtime query/update dispatch' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::RuntimeHandlerGetters',
    );

    # Init: the body runs the set/get checks synchronously, installs the
    # runtime query + update handlers, then parks on wait_condition.
    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'RuntimeHandlerGetters',
                arguments     => [],
            } },
        ],
    }));
    T2->ok(!(grep { $_->which_variant eq 'fail_workflow_execution' } @init),
        'the set/get prologue did not fail the workflow');

    # The runtime-registered query handler answers a QueryWorkflow job.
    my @q = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [
            { query_workflow => {
                query_id   => 'q1',
                query_type => 'qstate',
                arguments  => [],
            } },
        ],
    }));
    my ($qr) = grep { $_->which_variant eq 'respond_to_query' } @q;
    T2->ok($qr, 'the runtime query handler produced a RespondToQuery');
    T2->is($qr->respond_to_query->query_id, 'q1', 'response matches the query id');
    T2->is($PC->from_payload($qr->respond_to_query->succeeded->response),
        'count=0', 'the runtime query handler returned the workflow state');

    # The runtime-registered update handler accepts and completes a DoUpdate.
    my @u = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 120 },
        jobs      => [
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-1',
                name                 => 'bump',
                input                => [ payload(5) ],
                run_validator        => 1,
            } },
        ],
    }));
    my @ur = grep { $_->which_variant eq 'update_response' } @u;
    T2->is(scalar @ur, 2, 'accepted + completed for the runtime update handler');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the runtime update was accepted');
    T2->is($ur[1]->update_response->which_response, 'completed',
        'the runtime update completed');
    T2->is($PC->from_payload($ur[1]->update_response->completed), 5,
        'the runtime update handler returned the new counter');

    # The runtime-registered VALIDATOR rejects a bad input (single rejected).
    my @bad = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 130 },
        jobs      => [
            { do_update => {
                id                   => 'u-2',
                protocol_instance_id => 'pi-2',
                name                 => 'bump',
                input                => [ payload(-1) ],
                run_validator        => 1,
            } },
        ],
    }));
    my @bad_ur = grep { $_->which_variant eq 'update_response' } @bad;
    T2->is(scalar @bad_ur, 1, 'exactly one UpdateResponse for the rejected update');
    T2->is($bad_ur[0]->update_response->which_response, 'rejected',
        'the runtime validator rejected the bad input');

    # Finish: the completion carries every getter/unset check as name=1.
    my @done = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 140 },
        jobs      => [
            { signal_workflow => { signal_name => 'finish', input => [] } },
        ],
    }));
    my ($complete) =
        grep { $_->which_variant eq 'complete_workflow_execution' } @done;
    T2->ok($complete, 'the workflow completes');
    T2->is($PC->from_payload($complete->complete_workflow_execution->result),
        'sig_get=1,sig_unset=1,attr_get=1,query_get=1,query_unset=1,'
            . 'update_get=1,update_unset=1',
        'every getter/unset check passed inside the workflow');
});

T2->done_testing;
