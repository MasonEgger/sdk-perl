# ABOUTME: Request-capture tests for R82 (parity schedule/runtime finding 1):
# ABOUTME: StartWorkflow schedule action static_summary/static_details encode
# ABOUTME: into NewWorkflowExecutionInfo.user_metadata; none when absent.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Scalar::Util ();

use Temporalio::Client ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Schedule ();

Temporalio::Core::Proto->load;

# Per-object RPC mock registry keyed by client refaddr (the schedule_request.t
# harness); captures the CreateScheduleRequest actually emitted.
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
        namespace      => 'ns-meta',
        identity       => 'id-meta@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# Capture every (rpc, request) pair; every call resolves to undef.
sub capture ($client) {
    my @calls;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request };
        return Future->done(undef);
    };
    return \@calls;
}

sub a_schedule (%action_fields) {
    return Temporalio::Schedule::Schedule->new(
        action => Temporalio::Schedule::Action::StartWorkflow->new(
            workflow   => 'MetaWorkflow',
            id         => 'sched-meta-wf',
            task_queue => 'tq-meta',
            %action_fields,
        ),
        spec => Temporalio::Schedule::Spec->new(
            intervals => [ Temporalio::Schedule::Interval->new(every => 3600) ]),
    );
}

# ---------------------------------------------------------------------------
# static_summary + static_details -> encoded payloads on the emitted
# NewWorkflowExecutionInfo.user_metadata (sdk-python client/_schedule.py
# _to_proto's _encode_user_metadata call; fields declared at :551-552).
# ---------------------------------------------------------------------------
T2->subtest('static_summary and static_details encode into user_metadata' => sub {
    my $client = make_client;
    my $calls  = capture($client);
    $client->create_schedule('sched-meta', a_schedule(
        static_summary => 'fires the nightly sync',
        static_details => 'longer form details about the nightly sync',
    ))->get;

    T2->is(scalar(@$calls), 1, 'one RPC');
    my $info = $calls->[0]{request}->schedule->action->start_workflow;
    my $metadata = $info->user_metadata;
    T2->ok(defined $metadata, 'user_metadata set on NewWorkflowExecutionInfo');
    T2->is($metadata->summary->metadata->{encoding}, 'json/plain',
        'summary payload json/plain');
    T2->is($metadata->summary->data, '"fires the nightly sync"',
        'summary data (JSON string)');
    T2->is($metadata->details->metadata->{encoding}, 'json/plain',
        'details payload json/plain');
    T2->is($metadata->details->data,
        '"longer form details about the nightly sync"',
        'details data (JSON string)');

    # accessors surface the values the caller passed
    my $action = a_schedule(static_summary => 's', static_details => 'd')->action;
    T2->is($action->static_summary, 's', 'static_summary accessor');
    T2->is($action->static_details, 'd', 'static_details accessor');
});

# ---------------------------------------------------------------------------
# An action without them emits no user_metadata at all.
# ---------------------------------------------------------------------------
T2->subtest('an action without them emits no user_metadata' => sub {
    my $client = make_client;
    my $calls  = capture($client);
    $client->create_schedule('sched-plain', a_schedule())->get;

    T2->is(scalar(@$calls), 1, 'one RPC');
    my $info = $calls->[0]{request}->schedule->action->start_workflow;
    T2->ok(!defined $info->user_metadata, 'no user_metadata when both absent');
});

T2->done_testing;
