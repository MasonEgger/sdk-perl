# ABOUTME: Parity test for finding A17 / spec R69 (backfills divergence):
# ABOUTME: Python create_schedule takes `backfill` (singular, _client.py:2675)
# ABOUTME: while this SDK shipped only Ruby-style `backfills` (client.rb:684).
# ABOUTME: Both kwarg forms must reach CreateScheduleRequest.initial_patch.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Scalar::Util ();

use Temporalio::Client ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Schedule ();

Temporalio::Core::Proto->load;

# Per-object RPC mock registry keyed by client refaddr (the established
# pattern from t/unit/schedule_request.t).
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

sub record_calls ($client) {
    my @calls;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request };
        return Future->done(undef);
    };
    return \@calls;
}

sub a_schedule {
    return Temporalio::Schedule::Schedule->new(
        action => Temporalio::Schedule::Action::StartWorkflow->new(
            workflow => 'ParityWorkflow', args => ['a'],
            id => 'parity-wf', task_queue => 'tq'),
        spec   => Temporalio::Schedule::Spec->new(
            intervals => [ Temporalio::Schedule::Interval->new(every => 3600) ]),
        policy => Temporalio::Schedule::Policy->new(overlap => 'skip'),
        state  => Temporalio::Schedule::State->new,
    );
}

sub a_backfill {
    return Temporalio::Schedule::Backfill->new(
        start_at => 1_700_000_000,
        end_at   => 1_700_003_600,
        overlap  => 'buffer_all',
    );
}

# Assert the backfill window landed on the emitted CreateScheduleRequest,
# matching what Python _impl.py:1184-1194 puts on the wire.
sub assert_backfill_on_request ($req, $label) {
    T2->ok(defined $req->initial_patch, "$label: initial_patch present");
    my $br = $req->initial_patch->backfill_request;
    T2->is(scalar(@$br), 1, "$label: one backfill_request");
    T2->is($br->[0]->start_time->seconds, 1_700_000_000, "$label: start_time");
    T2->is($br->[0]->end_time->seconds, 1_700_003_600, "$label: end_time");
    T2->is($br->[0]->overlap_policy, 3, "$label: overlap (buffer_all -> 3)");
}

# ---------------------------------------------------------------------------
# Python form: create_schedule(..., backfill => [...]) (singular kwarg,
# ../sdk-python/temporalio/client/_client.py:2675). The A17 divergence:
# this threw the unknown-option Argument error before R69.
# ---------------------------------------------------------------------------
T2->subtest('Python-parity backfill kwarg reaches the request' => sub {
    my $client = make_client;
    my $calls  = record_calls($client);
    $client->create_schedule('parity-py', a_schedule(),
        backfill => [a_backfill()])->get;

    T2->is(scalar(@$calls), 1, 'one RPC');
    T2->is($calls->[0]{rpc}, 'CreateSchedule', 'CreateSchedule rpc');
    assert_backfill_on_request($calls->[0]{request}, 'backfill (singular)');
});

# ---------------------------------------------------------------------------
# Shipped Ruby-style plural form keeps working
# (../sdk-ruby/temporalio/lib/temporalio/client.rb:684).
# ---------------------------------------------------------------------------
T2->subtest('backfills kwarg still reaches the request' => sub {
    my $client = make_client;
    my $calls  = record_calls($client);
    $client->create_schedule('parity-rb', a_schedule(),
        backfills => [a_backfill()])->get;

    T2->is(scalar(@$calls), 1, 'one RPC');
    assert_backfill_on_request($calls->[0]{request}, 'backfills (plural)');
});

# ---------------------------------------------------------------------------
# Both forms at once is ambiguous: typed Argument, no RPC.
# ---------------------------------------------------------------------------
T2->subtest('backfill and backfills together -> Argument' => sub {
    my $client = make_client;
    my $calls  = record_calls($client);
    my $err = T2->dies(sub {
        $client->create_schedule('parity-both', a_schedule(),
            backfill  => [a_backfill()],
            backfills => [a_backfill()])->get;
    });
    T2->ok($err && $err->isa('Temporalio::Exception::Argument'),
        'both kwarg forms -> Argument');
    T2->is(scalar(@$calls), 0, 'no RPC on ambiguous call');
});

T2->done_testing;
