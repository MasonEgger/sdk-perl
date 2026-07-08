# ABOUTME: Unit tests for the factored update-settlement core (spec R17,
# ABOUTME: finding L7): _update_settlement classifies a ready accepted-update
# ABOUTME: handler future into completed / rejected / task-failure / dropped
# ABOUTME: without dying, covering the done, failed (Temporal-failure and plain
# ABOUTME: die), and CANCELLED future states: cancelled formerly croaked at
# ABOUTME: ->result because it passes the ->failure check empty.
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
use Temporalio::Converter::Payload ();
use Temporalio::Core::Proto ();
use Temporalio::Exception ();
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Worker::WorkflowDispatcher ();

# ---------------------------------------------------------------------------
# The Future state table (finding L7; step-45 probe probe_l7_cancelled_result.pl,
# re-verified while writing this test on Future 0.51 / perl 5.38.2):
#
#   state      is_ready  is_cancelled  ->failure  ->result
#   done       1         0             ()         the value
#   failed     1         0             ($err)     croaks with $err
#   cancelled  1         1             ()         croaks "... was cancelled"
#
# A cancelled future is READY but carries neither a result nor a failure, so a
# settle path that checks ->failure then calls ->result croaks on it. The
# settle core must discriminate ->is_cancelled FIRST. The settlement contract
# (spec section 19.2 step 4 plus the R17 eviction rule, sdk-python parity):
#
#   done                        -> { completed => $payload }
#   failed, Temporal failure    -> { rejected => $failure_proto } (post-accept)
#   failed, plain die           -> { task_failure => $err }
#   cancelled                   -> { dropped => 1 }  (eviction: no response,
#                                    matching sdk-python's _deleting swallow in
#                                    _workflow_instance.py run_update)
# ---------------------------------------------------------------------------

my $Activation = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_activation.WorkflowActivation');

my $PC = Temporalio::Converter::Payload->default;

# A live Runner to host the settle core: dispatch an init activation for
# WfDef::PlainFutureUpdater (its :Run parks on a plain untracked future, so the
# runner stays cached and alive) and pull the runner out of the dispatcher.
sub live_runner () {
    my $registry = Temporalio::Worker::WorkflowRegistry->new(
        workflows => ['WfDef::PlainFutureUpdater']);
    my $dispatcher = Temporalio::Worker::WorkflowDispatcher->new(
        registry       => $registry,
        data_converter => Temporalio::Converter::Data->new,
        task_queue     => 'demo',
        completer      => sub ($bytes) { return Future->done },
    );
    $dispatcher->dispatch_task($Activation->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'PlainFutureUpdater' } },
        ],
    })->encode)->get;
    my $runner = $dispatcher->runner('r1');
    T2->ok(defined $runner, 'dispatcher holds a live runner for r1');
    return $runner;
}

T2->subtest('probe: the cancelled-future state the settle core must survive' => sub {
    my $f = Future->new;
    $f->cancel;
    T2->ok($f->is_ready,       'a cancelled future IS ready');
    T2->ok($f->is_cancelled,   'and reports is_cancelled');
    T2->is([$f->failure], [],  'but its ->failure is EMPTY (passes the check)');
    my $croak = T2->dies(sub { $f->result });
    T2->like($croak, qr/cancelled/,
        '->result on it croaks: the pre-fix _settle_update death (L7)');
});

T2->subtest('done future -> completed with the encoded result' => sub {
    my $runner = live_runner();
    my $s = $runner->_update_settlement(Future->done('handler-value'));
    T2->ok(defined $s->{completed}, 'settlement is completed');
    T2->is($PC->from_payload($s->{completed}), 'handler-value',
        'completed carries the encoded handler return value');
});

T2->subtest('failed future (Temporal failure type) -> rejected' => sub {
    my $runner = live_runner();
    my $s = $runner->_update_settlement(
        Future->fail(Temporalio::Exception->new(message => 'boom')));
    T2->ok(defined $s->{rejected}, 'settlement is rejected (post-accept)');
    T2->is($s->{rejected}->message, 'boom',
        'rejected carries the converted failure');
});

T2->subtest('failed future (plain die) -> task failure' => sub {
    my $runner = live_runner();
    my $s = $runner->_update_settlement(Future->fail("plain death\n"));
    T2->is($s->{task_failure}, "plain death\n",
        'a plain die post-acceptance routes to a workflow TASK failure');
    T2->ok(!defined $s->{rejected}, 'and is not an update rejection');
});

T2->subtest('cancelled future -> dropped, without dying (R17)' => sub {
    my $runner = live_runner();
    my $cancelled = Future->new;
    $cancelled->cancel;
    my $s;
    my $err = T2->dies(sub { $s = $runner->_update_settlement($cancelled) });
    T2->is($err, undef, 'the settle core survives a cancelled future');
    T2->is($s, { dropped => 1 },
        'a cancelled handler future is DROPPED per the eviction contract '
        . '(no UpdateResponse, no activation error: sdk-python parity)');

    # And the real settle path lives too: _settle_update on a cancelled future
    # was the exact pre-fix croak site.
    my $another = Future->new;
    $another->cancel;
    my $settle_err =
        T2->dies(sub { $runner->_settle_update('pi-x', $another) });
    T2->is($settle_err, undef, '_settle_update lives on a cancelled future');
});

T2->done_testing;
