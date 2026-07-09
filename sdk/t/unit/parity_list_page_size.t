# ABOUTME: Parity test for finding A17 / spec R69 (page-size divergence):
# ABOUTME: Python defaults page_size to 1000 on list_workflows
# ABOUTME: (_client.py:1230) and list_schedules (_client.py:2732) and always
# ABOUTME: sends it; this SDK sent nothing when the caller omitted page_size.
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

# Per-object RPC mock registry keyed by client refaddr (the established
# pattern from t/unit/parity_backfills.t / t/unit/schedule_request.t).
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

# Record every RPC and answer each with an empty response of the right type
# so the iterator's response handling runs (one page, no next_page_token).
sub record_calls ($client) {
    my @calls;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request };
        my $Response = Temporalio::Core::Proto::resolve(
            "temporal.api.workflowservice.v1.${rpc}Response");
        return Future->done($Response->new({}));
    };
    return \@calls;
}

# ---------------------------------------------------------------------------
# list_workflows with page_size omitted: Python sends its default of 1000 on
# every ListWorkflowExecutionsRequest (../sdk-python/temporalio/client/
# _client.py:1230). The A17 divergence: this SDK sent no page_size at all.
# ---------------------------------------------------------------------------
T2->subtest('list_workflows default page_size 1000 reaches the request' => sub {
    my $client = make_client;
    my $calls  = record_calls($client);
    my $iter   = $client->list_workflows('WorkflowType="Parity"');
    T2->is(scalar(@$calls), 0, 'lazy: no RPC before the first next');
    my $got = $iter->next->get;
    T2->is($got, undef, 'empty page -> undef');
    T2->is(scalar(@$calls), 1, 'one RPC');
    T2->is($calls->[0]{rpc}, 'ListWorkflowExecutions',
        'ListWorkflowExecutions rpc');
    T2->is($calls->[0]{request}->page_size, 1000,
        'page_size defaults to 1000 (Python parity)');
});

# ---------------------------------------------------------------------------
# list_schedules with page_size omitted: Python defaults to 1000 too
# (../sdk-python/temporalio/client/_client.py:2732); the ListSchedulesRequest
# field is maximum_page_size.
# ---------------------------------------------------------------------------
T2->subtest('list_schedules default maximum_page_size 1000' => sub {
    my $client = make_client;
    my $calls  = record_calls($client);
    my $iter   = $client->list_schedules;
    my $got    = $iter->next->get;
    T2->is($got, undef, 'empty page -> undef');
    T2->is(scalar(@$calls), 1, 'one RPC');
    T2->is($calls->[0]{rpc}, 'ListSchedules', 'ListSchedules rpc');
    T2->is($calls->[0]{request}->maximum_page_size, 1000,
        'maximum_page_size defaults to 1000 (Python parity)');
});

# ---------------------------------------------------------------------------
# An explicit page_size still wins over the default on both methods.
# ---------------------------------------------------------------------------
T2->subtest('explicit page_size overrides the default' => sub {
    my $client = make_client;
    my $calls  = record_calls($client);
    $client->list_workflows(undef, page_size => 50)->next->get;
    $client->list_schedules(undef, page_size => 25)->next->get;
    T2->is(scalar(@$calls), 2, 'two RPCs');
    T2->is($calls->[0]{request}->page_size, 50,
        'explicit list_workflows page_size sent');
    T2->is($calls->[1]{request}->maximum_page_size, 25,
        'explicit list_schedules page_size sent');
});

T2->done_testing;
