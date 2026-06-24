# ABOUTME: Unit tests for spec section 25 ScheduleHandle operations: the
# ABOUTME: Patch/Delete/Update request builders, default pause/unpause notes,
# ABOUTME: empty-backfill Argument, single-shot update (updater invoked once,
# ABOUTME: falsy -> no RPC), describe round-trip, and the duplicate-create ->
# ABOUTME: ScheduleAlreadyRunning re-map (T-sched-4) via a stubbed ALREADY_EXISTS.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Future::AsyncAwait;
use Scalar::Util ();

use Temporalio::Client ();
use Temporalio::Client::ScheduleHandle ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::RpcError ();
use Temporalio::Exception::ScheduleAlreadyRunning ();
use Temporalio::Schedule ();

Temporalio::Core::Proto->load;

sub resolve { Temporalio::Core::Proto::resolve($_[0]) }

# Per-object RPC mock registry, keyed by client refaddr (the same pattern as
# t/unit/schedule_request.t and workflow_handle_result.t — the glob override is
# seen by the class-method dispatch).
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
        namespace      => 'ns-h',
        identity       => 'id-h@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# Install a mock recording every (rpc, request) and returning the next canned
# value (a responder coderef called with ($rpc, $request); may die to fail).
sub script ($client, @responders) {
    my @calls;
    my $i = 0;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request };
        my $r = $responders[$i++] // sub { undef };
        my $value = do { local $@; eval { $r->($rpc, $request) } };
        return Future->fail($@) if $@;
        return Future->done($value);
    };
    return \@calls;
}

sub a_schedule (%override) {
    return Temporalio::Schedule::Schedule->new(
        action => Temporalio::Schedule::Action::StartWorkflow->new(
            workflow => 'MyWorkflow', args => ['arg1'],
            id => 'sched-wf', task_queue => 'tq'),
        spec   => Temporalio::Schedule::Spec->new(
            intervals => [ Temporalio::Schedule::Interval->new(every => 3600) ]),
        policy => Temporalio::Schedule::Policy->new(
            overlap => $override{overlap} // 'buffer_one'),
        state  => $override{state} // Temporalio::Schedule::State->new,
    );
}

# Build a real DescribeScheduleResponse from a schedule for describe()/update().
sub a_describe_response ($client, $schedule) {
    my $Response = resolve(
        'temporal.api.workflowservice.v1.DescribeScheduleResponse');
    my $Info = resolve('temporal.api.schedule.v1.ScheduleInfo');
    return $Response->new({
        schedule => $schedule->_to_proto($client)->get,
        info     => $Info->new({ action_count => 3 }),
    });
}

# ---------------------------------------------------------------------------
# delete: DeleteScheduleRequest carries NO request_id (T-sched unit).
# ---------------------------------------------------------------------------
T2->subtest('delete builds DeleteScheduleRequest (no request_id)' => sub {
    my $client = make_client;
    my $calls  = script($client, sub { undef });
    my $h = $client->get_schedule_handle('s-del');
    $h->delete->get;

    T2->is(scalar(@$calls), 1, 'one RPC');
    T2->is($calls->[0]{rpc}, 'DeleteSchedule', 'DeleteSchedule rpc');
    my $req = $calls->[0]{request};
    T2->is($req->namespace, 'ns-h', 'namespace');
    T2->is($req->schedule_id, 's-del', 'schedule_id');
    T2->is($req->identity, 'id-h@host', 'identity');
    # DeleteScheduleRequest has no request_id field — the accessor must not exist.
    T2->ok(!$req->can('request_id'),
        'DeleteScheduleRequest has no request_id field');
});

# ---------------------------------------------------------------------------
# pause / unpause: default notes exact; PatchSchedule.pause/unpause string.
# ---------------------------------------------------------------------------
T2->subtest('pause/unpause default notes + PatchSchedule' => sub {
    my $client = make_client;
    my $calls  = script($client, sub { undef }, sub { undef },
        sub { undef }, sub { undef });
    my $h = $client->get_schedule_handle('s-pause');

    $h->pause->get;
    $h->unpause->get;
    $h->pause(note => 'custom pause')->get;
    $h->unpause(note => 'custom unpause')->get;

    T2->is(scalar(@$calls), 4, 'four PatchSchedule RPCs');
    T2->is($calls->[0]{rpc}, 'PatchSchedule', 'pause -> PatchSchedule');

    my $r0 = $calls->[0]{request};
    T2->is($r0->namespace, 'ns-h', 'patch namespace');
    T2->is($r0->schedule_id, 's-pause', 'patch schedule_id');
    T2->is($r0->identity, 'id-h@host', 'patch identity');
    T2->ok(length($r0->request_id // ''), 'patch request_id set');
    T2->is($r0->patch->pause, 'Paused via Perl SDK', 'default pause note');

    T2->is($calls->[1]{request}->patch->unpause, 'Unpaused via Perl SDK',
        'default unpause note');
    T2->is($calls->[2]{request}->patch->pause, 'custom pause',
        'custom pause note honored');
    T2->is($calls->[3]{request}->patch->unpause, 'custom unpause',
        'custom unpause note honored');
});

# ---------------------------------------------------------------------------
# trigger: PatchSchedule.trigger_immediately; overlap override / default 0.
# ---------------------------------------------------------------------------
T2->subtest('trigger builds PatchSchedule.trigger_immediately' => sub {
    my $client = make_client;
    my $calls  = script($client, sub { undef }, sub { undef });
    my $h = $client->get_schedule_handle('s-trig');

    $h->trigger->get;
    $h->trigger(overlap => 'allow_all')->get;

    T2->is(scalar(@$calls), 2, 'two PatchSchedule RPCs');
    T2->is($calls->[0]{rpc}, 'PatchSchedule', 'trigger -> PatchSchedule');
    my $t0 = $calls->[0]{request}->patch->trigger_immediately;
    T2->ok(defined $t0, 'trigger_immediately set');
    T2->is($t0->overlap_policy, 0, 'default overlap unspecified (0)');

    my $t1 = $calls->[1]{request}->patch->trigger_immediately;
    T2->is($t1->overlap_policy, 6, 'overlap override allow_all -> 6');
});

# ---------------------------------------------------------------------------
# backfill: at least one required; PatchSchedule.backfill_request list.
# ---------------------------------------------------------------------------
T2->subtest('backfill builds PatchSchedule + empty -> Argument' => sub {
    my $client = make_client;
    my $calls  = script($client, sub { undef });
    my $h = $client->get_schedule_handle('s-bf');

    my $bf1 = Temporalio::Schedule::Backfill->new(
        start_at => 1_700_000_000, end_at => 1_700_003_600, overlap => 'skip');
    my $bf2 = Temporalio::Schedule::Backfill->new(
        start_at => 1_700_010_000, end_at => 1_700_013_600,
        overlap => 'allow_all');
    $h->backfill($bf1, $bf2)->get;

    T2->is(scalar(@$calls), 1, 'one PatchSchedule RPC');
    my $br = $calls->[0]{request}->patch->backfill_request;
    T2->is(scalar(@$br), 2, 'two backfill_request entries');
    T2->is($br->[0]->start_time->seconds, 1_700_000_000, 'first backfill start');
    T2->is($br->[1]->overlap_policy, 6, 'second backfill overlap allow_all -> 6');

    my $bad = T2->dies(sub { $h->backfill->get });
    T2->ok($bad && $bad->isa('Temporalio::Exception::Argument'),
        'empty backfill -> Argument');
    T2->is(scalar(@$calls), 1, 'no extra RPC on empty backfill');
});

# ---------------------------------------------------------------------------
# describe: DescribeSchedule -> Schedule::Description; action args kept raw.
# ---------------------------------------------------------------------------
T2->subtest('describe builds DescribeScheduleRequest + Description' => sub {
    my $client = make_client;
    my $sched  = a_schedule();
    my $resp   = a_describe_response($client, $sched);
    my $calls  = script($client, sub { $resp });
    my $h = $client->get_schedule_handle('s-desc');

    my $desc = $h->describe->get;

    T2->is(scalar(@$calls), 1, 'one RPC');
    T2->is($calls->[0]{rpc}, 'DescribeSchedule', 'DescribeSchedule rpc');
    my $req = $calls->[0]{request};
    T2->is($req->namespace, 'ns-h', 'describe namespace');
    T2->is($req->schedule_id, 's-desc', 'describe schedule_id');

    T2->isa_ok($desc, ['Temporalio::Schedule::Description'],
        'returns a Description');
    T2->is($desc->id, 's-desc', 'description id');
    T2->is($desc->info->num_actions, 3, 'info action_count decoded');
    T2->is($desc->schedule->action->workflow, 'MyWorkflow',
        'action workflow decoded');
});

# ---------------------------------------------------------------------------
# update: single-shot; describe then UpdateSchedule replacing the schedule;
# updater invoked exactly once.
# ---------------------------------------------------------------------------
T2->subtest('update single-shot describe -> UpdateSchedule' => sub {
    my $client = make_client;
    my $sched  = a_schedule();
    my $resp   = a_describe_response($client, $sched);
    my $calls  = script($client, sub { $resp }, sub { undef });
    my $h = $client->get_schedule_handle('s-upd');

    my $invocations = 0;
    my $new = a_schedule(overlap => 'allow_all');
    $h->update(sub ($input) {
        $invocations++;
        T2->isa_ok($input, ['Temporalio::Schedule::Update::Input'],
            'updater gets an Update::Input');
        T2->is($input->description->id, 's-upd', 'input description id');
        return Temporalio::Schedule::Update->new(schedule => $new);
    })->get;

    T2->is($invocations, 1, 'updater invoked exactly once (single-shot)');
    T2->is(scalar(@$calls), 2, 'describe + update (two RPCs)');
    T2->is($calls->[0]{rpc}, 'DescribeSchedule', 'first RPC describe');
    T2->is($calls->[1]{rpc}, 'UpdateSchedule', 'second RPC UpdateSchedule');

    my $req = $calls->[1]{request};
    T2->is($req->namespace, 'ns-h', 'update namespace');
    T2->is($req->schedule_id, 's-upd', 'update schedule_id');
    T2->is($req->identity, 'id-h@host', 'update identity');
    T2->ok(length($req->request_id // ''), 'update request_id set');
    T2->is($req->schedule->policies->overlap_policy, 6,
        'update replaced schedule (allow_all -> 6)');
});

# ---------------------------------------------------------------------------
# update: falsy return -> describe only, NO UpdateSchedule RPC.
# ---------------------------------------------------------------------------
T2->subtest('update falsy -> no UpdateSchedule RPC' => sub {
    my $client = make_client;
    my $resp   = a_describe_response($client, a_schedule());
    my $calls  = script($client, sub { $resp });
    my $h = $client->get_schedule_handle('s-noop');

    my $invocations = 0;
    $h->update(sub ($input) { $invocations++; return undef })->get;

    T2->is($invocations, 1, 'updater still invoked once');
    T2->is(scalar(@$calls), 1, 'only describe RPC (no update)');
    T2->is($calls->[0]{rpc}, 'DescribeSchedule', 'describe only');
});

# ---------------------------------------------------------------------------
# update: updater may return a Future resolving to the Update (awaited).
# ---------------------------------------------------------------------------
T2->subtest('update awaits a Future-returning updater' => sub {
    my $client = make_client;
    my $resp   = a_describe_response($client, a_schedule());
    my $calls  = script($client, sub { $resp }, sub { undef });
    my $h = $client->get_schedule_handle('s-fut');

    my $new = a_schedule();
    $h->update(sub ($input) {
        return Future->done(
            Temporalio::Schedule::Update->new(schedule => $new));
    })->get;

    T2->is(scalar(@$calls), 2, 'describe + update');
    T2->is($calls->[1]{rpc}, 'UpdateSchedule', 'awaited Future update applied');
});

# ---------------------------------------------------------------------------
# T-sched-4: duplicate create -> ScheduleAlreadyRunning via stubbed
# ALREADY_EXISTS (code 6). Re-confirmed here from the handle path's client.
# ---------------------------------------------------------------------------
T2->subtest('duplicate create -> ScheduleAlreadyRunning (T-sched-4)' => sub {
    my $client = make_client;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        return Future->fail(Temporalio::Exception::RpcError->new(
            message => 'already exists', status_code => 6));
    };
    my $err = T2->dies(sub {
        $client->create_schedule('dup-h', a_schedule())->get;
    });
    T2->ok($err && $err->isa('Temporalio::Exception::ScheduleAlreadyRunning'),
        'stubbed ALREADY_EXISTS -> ScheduleAlreadyRunning');
    T2->is($err->schedule_id, 'dup-h', 'carries schedule id');
});

T2->done_testing;
