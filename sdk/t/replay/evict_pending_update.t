# ABOUTME: Regression repro for R17 (finding L7): evicting a run holding a
# ABOUTME: pending async :Update croaked in _settle_update. evict() natively
# ABOUTME: cancels the tracked handler future, its on_ready settles the update,
# ABOUTME: and a CANCELLED future passes the ->failure check EMPTY and then
# ABOUTME: ->result croaks ("... was cancelled"), so the eviction completion was
# ABOUTME: never sent and the run's cache slot wedged.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
no warnings 'experimental::class';

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;

use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Worker::WorkflowDispatcher ();

# ---------------------------------------------------------------------------
# The defect (finding L7, spec R17; Future semantics from the step-45 probe
# probe_l7_cancelled_result.pl, re-verified for this test):
#
#   state      is_ready  is_cancelled  ->failure  ->result
#   done       1         0             ()         the value
#   failed     1         0             ($err)     croaks with $err
#   cancelled  1         1             ()         croaks "... was cancelled"
#
#   _settle_update handled done and failed futures but not cancelled ones: the
#   cancelled handler future passed the empty ->failure check and then ->result
#   croaked. The only producer of a NATIVELY CANCELLED handler future is
#   evict(): its %in_progress_handlers sweep calls ->cancel on the tracked
#   update-handler future, whose on_ready fires _settle_update synchronously
#   mid-evict. The croak escaped evict(), the dispatcher's _handle_eviction
#   never sent the empty-success eviction completion, and core never saw the
#   eviction ack. (The whole-workflow cancel chain is NOT this shape: it
#   throws a Temporalio::Exception::Cancelled INTO the handler, so the handler
#   future FAILS and takes the rejected branch.)
#
#   Fixture shape matters: Future::AsyncAwait clones the handler's method
#   future from the FIRST awaited future, so only a handler parked on a plain
#   Temporalio::Workflow::Future (native cancel; WfDef::PlainFutureUpdater,
#   the update analog of R9's PlainFutureParker) reaches the cancelled state.
#   A wait_condition-parked handler clones _ConditionFuture, whose cancel
#   override FAILS the handler future with Cancelled instead (the rejected
#   branch, not this defect).
#
# Fixed by discriminating ->is_cancelled in the settle core before touching
# ->result and DROPPING the update (no UpdateResponse), matching sdk-python:
# on eviction the update task's teardown exception is swallowed with no
# response emitted (_workflow_instance.py run_update, `except BaseException`
# under self._deleting). Deterministic replay (no server, no IO::Async
# timers); the dispatcher path mirrors evict-sibling-delete.t so the test can
# assert the eviction completion is actually SENT.
# ---------------------------------------------------------------------------

my $Activation = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_activation.WorkflowActivation');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_completion.WorkflowActivationCompletion');

# Activations resolve synchronously here (the Runner drives workflow Futures
# imperatively, no IO::Async), so ->get pumps them to completion.
sub await_f ($f) { return $f->get }

sub activation_bytes ($run_id, $jobs, %opt) {
    return $Activation->new({
        run_id    => $run_id,
        timestamp => { seconds => $opt{seconds} // 100 },
        jobs      => $jobs,
    })->encode;
}

# Build a dispatcher over the given workflow classes; $completions collects the
# raw completion bytes handed to the injected completer.
sub build_dispatcher (%args) {
    my $registry = Temporalio::Worker::WorkflowRegistry->new(
        workflows => $args{workflows});
    my $completions = [];
    my $dispatcher  = Temporalio::Worker::WorkflowDispatcher->new(
        registry       => $registry,
        data_converter => Temporalio::Converter::Data->new,
        task_queue     => 'demo',
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
    );
    return ($dispatcher, $completions);
}

T2->subtest('evict with a pending async update completes without croaking (R17)' => sub {
    # WfDef::PlainFutureUpdater: :Run and the `park` :Update handler each park
    # on a plain untracked Temporalio::Workflow::Future, so after the do_update
    # activation the accepted update's handler future sits pending in
    # %in_progress_handlers with NATIVE cancel semantics: the exact entry
    # evict() natively cancels into the L7 state.
    my ($dispatcher, $completions) =
        build_dispatcher(workflows => ['WfDef::PlainFutureUpdater']);

    await_f($dispatcher->dispatch_task(
        activation_bytes('r1', [
            { initialize_workflow => { workflow_type => 'PlainFutureUpdater' } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-1',
                name                 => 'park',
                run_validator        => 1,
            } },
        ])));

    # Setup sanity: the update was ACCEPTED but not completed: the handler
    # future is mid-flight (parked), which is what makes the eviction sweep
    # cancel it.
    my $c0 = $Completion->decode($completions->[0]);
    my @ur = grep { $_->which_variant eq 'update_response' }
        ($c0->successful->commands // [])->@*;
    T2->is(scalar @ur, 1, 'exactly one UpdateResponse in the setup activation');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the update was accepted with its handler still in flight');

    # The crux: the eviction activation. Under the bug, evict() cancels the
    # tracked handler future, its on_ready calls _settle_update, the cancelled
    # future passes ->failure empty, and ->result croaks "was cancelled";
    # evict dies and no completion is ever sent.
    my $err = T2->dies(sub {
        await_f($dispatcher->dispatch_task(
            activation_bytes('r1',
                [ { remove_from_cache => { message => 'cache full' } } ])));
    });
    T2->is($err, undef,
        'evict survives the cancelled in-flight update handler (no croak)');

    T2->ok(!$dispatcher->has_runner('r1'), 'runner dropped after eviction');
    T2->is(scalar(@$completions), 2, 'the eviction completion was sent');
    my $c1 = $Completion->decode($completions->[-1]);
    T2->ok(defined $c1->successful, 'eviction completion is the empty success');
    T2->is(scalar(($c1->successful->commands // [])->@*), 0,
        'eviction completion carries no commands (the pending update is '
        . 'DROPPED, not rejected; sdk-python parity)');
});

T2->done_testing;
