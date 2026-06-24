# ABOUTME: Unit tests for spec section 25 client schedule request builders:
# ABOUTME: create_schedule's CreateScheduleRequest (initial_patch only on
# ABOUTME: trigger/backfills, trigger overlap from the schedule policy, the
# ABOUTME: limited/remaining invariant -> Argument, ALREADY_EXISTS ->
# ABOUTME: ScheduleAlreadyRunning), get_schedule_handle (no RPC), and the lazy
# ABOUTME: list_schedules iterator request shape.
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
# t/unit/workflow_handle_result.t — the glob override is seen by the class
# method dispatch).
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
        namespace      => 'ns-req',
        identity       => 'id-req@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# Install a mock recording every (rpc, request) and returning the next canned
# value (or failing on a responder that dies). Returns the calls arrayref.
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

# ---------------------------------------------------------------------------
# get_schedule_handle: no RPC.
# ---------------------------------------------------------------------------
T2->subtest('get_schedule_handle no RPC' => sub {
    my $client = make_client;
    my $calls  = script($client);
    my $h = $client->get_schedule_handle('my-sched');
    T2->isa_ok($h, ['Temporalio::Client::ScheduleHandle'], 'returns a handle');
    T2->is($h->id, 'my-sched', 'handle id');
    T2->is($h->client, $client, 'handle client');
    T2->is(scalar(@$calls), 0, 'no RPC made');

    my $bad = T2->dies(sub { $client->get_schedule_handle('') });
    T2->ok($bad && $bad->isa('Temporalio::Exception::Argument'),
        'empty id -> Argument');
});

# ---------------------------------------------------------------------------
# create_schedule basic: CreateScheduleRequest with no initial_patch.
# ---------------------------------------------------------------------------
T2->subtest('create_schedule basic request' => sub {
    my $client = make_client;
    my $calls  = script($client, sub { undef });
    my $h = $client->create_schedule('sched-1', a_schedule())->get;

    T2->isa_ok($h, ['Temporalio::Client::ScheduleHandle'], 'returns handle');
    T2->is($h->id, 'sched-1', 'handle id matches');
    T2->is(scalar(@$calls), 1, 'one RPC');
    T2->is($calls->[0]{rpc}, 'CreateSchedule', 'CreateSchedule rpc');

    my $req = $calls->[0]{request};
    T2->is($req->namespace, 'ns-req', 'namespace');
    T2->is($req->schedule_id, 'sched-1', 'schedule_id');
    T2->is($req->identity, 'id-req@host', 'identity');
    T2->ok(length($req->request_id // ''), 'request_id set');
    T2->ok(defined $req->schedule, 'schedule embedded');
    T2->is($req->schedule->policies->overlap_policy, 2, 'schedule policies overlap');
    T2->ok(!defined $req->initial_patch,
        'no initial_patch without trigger/backfills');
});

# ---------------------------------------------------------------------------
# create_schedule trigger_immediately: initial_patch trigger overlap from
# the schedule's OWN policy.
# ---------------------------------------------------------------------------
T2->subtest('create_schedule trigger_immediately initial_patch' => sub {
    my $client = make_client;
    my $calls  = script($client, sub { undef });
    $client->create_schedule('sched-2', a_schedule(overlap => 'allow_all'),
        trigger_immediately => 1)->get;

    my $req = $calls->[0]{request};
    T2->ok(defined $req->initial_patch, 'initial_patch present');
    my $trigger = $req->initial_patch->trigger_immediately;
    T2->ok(defined $trigger, 'trigger_immediately set');
    T2->is($trigger->overlap_policy, 6,
        'trigger overlap from schedule policy (allow_all -> 6)');
});

# ---------------------------------------------------------------------------
# create_schedule backfills: initial_patch backfill_request list.
# ---------------------------------------------------------------------------
T2->subtest('create_schedule backfills initial_patch' => sub {
    my $client = make_client;
    my $calls  = script($client, sub { undef });
    my $bf = Temporalio::Schedule::Backfill->new(
        start_at => 1_700_000_000, end_at => 1_700_003_600, overlap => 'skip');
    $client->create_schedule('sched-3', a_schedule(), backfills => [$bf])->get;

    my $req = $calls->[0]{request};
    T2->ok(defined $req->initial_patch, 'initial_patch present');
    my $br = $req->initial_patch->backfill_request;
    T2->is(scalar(@$br), 1, 'one backfill_request');
    T2->is($br->[0]->start_time->seconds, 1_700_000_000, 'backfill start');
});

# ---------------------------------------------------------------------------
# create_schedule memo/search_attributes encoding.
# ---------------------------------------------------------------------------
T2->subtest('create_schedule memo encoded' => sub {
    my $client = make_client;
    my $calls  = script($client, sub { undef });
    $client->create_schedule('sched-4', a_schedule(), memo => { k => 'v' })->get;
    my $req = $calls->[0]{request};
    T2->ok(defined $req->memo, 'memo encoded');
    T2->ok(exists $req->memo->fields->{k}, 'memo key present');
});

# ---------------------------------------------------------------------------
# limited/remaining invariant -> Argument BEFORE any RPC.
# ---------------------------------------------------------------------------
T2->subtest('limited/remaining invariant -> Argument' => sub {
    my $client = make_client;
    my $calls  = script($client);

    my $limited_no_rem = T2->dies(sub {
        $client->create_schedule('s', a_schedule(
            state => Temporalio::Schedule::State->new(limited_actions => 1)))->get;
    });
    T2->ok($limited_no_rem && $limited_no_rem->isa('Temporalio::Exception::Argument'),
        'limited_actions with zero remaining -> Argument');

    my $rem_no_limited = T2->dies(sub {
        $client->create_schedule('s', a_schedule(
            state => Temporalio::Schedule::State->new(remaining_actions => 5)))->get;
    });
    T2->ok($rem_no_limited && $rem_no_limited->isa('Temporalio::Exception::Argument'),
        'remaining without limited_actions -> Argument');

    T2->is(scalar(@$calls), 0, 'no RPC on invariant failure');
});

# ---------------------------------------------------------------------------
# unknown create_schedule kwargs -> Argument.
# ---------------------------------------------------------------------------
T2->subtest('unknown create_schedule kwarg -> Argument' => sub {
    my $client = make_client;
    script($client);
    my $bad = T2->dies(sub {
        $client->create_schedule('s', a_schedule(), bogus => 1)->get;
    });
    T2->ok($bad && $bad->isa('Temporalio::Exception::Argument'),
        'unknown kwarg -> Argument');
});

# ---------------------------------------------------------------------------
# ALREADY_EXISTS -> ScheduleAlreadyRunning (stubbed code-6 RpcError).
# ---------------------------------------------------------------------------
T2->subtest('duplicate -> ScheduleAlreadyRunning' => sub {
    my $client = make_client;
    # Fail directly with the RpcError object (Future->fail on a blessed object
    # keeps it intact for the catch in create_schedule).
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        return Future->fail(Temporalio::Exception::RpcError->new(
            message => 'already exists', status_code => 6));
    };
    my $err = T2->dies(sub {
        $client->create_schedule('dup', a_schedule())->get;
    });
    T2->ok($err && $err->isa('Temporalio::Exception::ScheduleAlreadyRunning'),
        'code-6 RpcError -> ScheduleAlreadyRunning');
    T2->is($err->schedule_id, 'dup', 'carries schedule id');
});

# ---------------------------------------------------------------------------
# list_schedules: lazy iterator, request shape, paging stop.
# ---------------------------------------------------------------------------
T2->subtest('list_schedules lazy iterator' => sub {
    my $Entry        = resolve('temporal.api.schedule.v1.ScheduleListEntry');
    my $ListInfo     = resolve('temporal.api.schedule.v1.ScheduleListInfo');
    my $WorkflowType = resolve('temporal.api.common.v1.WorkflowType');
    my $Response     = resolve(
        'temporal.api.workflowservice.v1.ListSchedulesResponse');

    my $client = make_client;
    my $calls  = script($client, sub {
        return $Response->new({
            schedules => [
                $Entry->new({
                    schedule_id => 'sched-a',
                    info => $ListInfo->new({
                        notes => 'n', paused => 1,
                        workflow_type => $WorkflowType->new({ name => 'W' }),
                    }),
                }),
            ],
            next_page_token => '',
        });
    });

    my $it = $client->list_schedules('WorkflowType="W"', page_size => 5);
    T2->is(scalar(@$calls), 0, 'no RPC until first next');

    my $first = $it->next->get;
    T2->is(scalar(@$calls), 1, 'one RPC after first next');
    T2->is($calls->[0]{rpc}, 'ListSchedules', 'ListSchedules rpc');
    T2->is($calls->[0]{request}->namespace, 'ns-req', 'request namespace');
    T2->is($calls->[0]{request}->query, 'WorkflowType="W"', 'request query');
    T2->is($calls->[0]{request}->maximum_page_size, 5,
        'page_size -> maximum_page_size');

    T2->isa_ok($first, ['Temporalio::Schedule::ListDescription'],
        'yields a ListDescription');
    T2->is($first->id, 'sched-a', 'list entry id');
    T2->is($first->workflow_type, 'W', 'list entry workflow type');
    T2->is($first->paused, 1, 'list entry paused');

    my $done = $it->next->get;
    T2->ok(!defined $done, 'exhausted iterator returns undef');
});

T2->done_testing;
