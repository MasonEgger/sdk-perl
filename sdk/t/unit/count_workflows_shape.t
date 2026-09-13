# ABOUTME: Pins the count_workflows return shape ahead of the I13 POD fix
# ABOUTME: (issue #13): the code has always returned { count, groups }
# ABOUTME: this assertion locks that shape, green from the start (R64 pattern).
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

# count_workflows resolves to { count => N, groups => [...] }
# (sdk/lib/Temporalio/Client.pm:298-300). Python's parallel contract is
# WorkflowExecutionCount(count, groups) built by
# ../sdk-python/temporalio/client/_impl.py:396-409 (count_workflows), whose
# _from_raw lives at ../sdk-python/temporalio/client/_workflow.py:1513-1522;
# each group is WorkflowExecutionCountAggregationGroup(count, group_values)
# assembled by _workflow.py:1537-1549. Perl leaves each group as the raw
# CountWorkflowExecutionsResponse.AggregationGroup proto message (count,
# group_values accessors) rather than decoding group_values into search
# attribute values -- the field names line up with Python's dataclass
# regardless.

# The same per-object _rpc_call mock registry as parity_list_page_size.t /
# parity_backfills.t / schedule_request.t.
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
        namespace      => 'ns-count',
        identity       => 'id-count@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

sub resolve { Temporalio::Core::Proto::resolve($_[0]) }

# ---------------------------------------------------------------------------
# Plain form: no group-by clause. groups comes back empty.
# ---------------------------------------------------------------------------
T2->subtest('count_workflows plain form resolves to { count, groups }' => sub {
    my $client = make_client;
    my $Response =
        resolve('temporal.api.workflowservice.v1.CountWorkflowExecutionsResponse');
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        T2->is($rpc, 'CountWorkflowExecutions', 'CountWorkflowExecutions rpc');
        return Future->done($Response->new({ count => 7 }));
    };

    my $result = $client->count_workflows('WorkflowType="Foo"')->get;
    T2->ref_ok($result, 'HASH', 'resolves to a hashref');
    T2->is($result->{count}, 7, 'count key carries the approximate count');
    T2->ref_ok($result->{groups}, 'ARRAY', 'groups key is present and an arrayref');
    T2->is(scalar(@{ $result->{groups} }), 0, 'no group-by clause -> empty groups');
});

# ---------------------------------------------------------------------------
# Group-by form: the response carries AggregationGroup buckets, each with its
# own count and group_values.
# ---------------------------------------------------------------------------
T2->subtest('count_workflows group-by form populates groups' => sub {
    my $client = make_client;
    my $Response =
        resolve('temporal.api.workflowservice.v1.CountWorkflowExecutionsResponse');
    my $Group = resolve(
        'temporal.api.workflowservice.v1.CountWorkflowExecutionsResponse.AggregationGroup');
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        return Future->done($Response->new({
            count  => 12,
            groups => [
                $Group->new({ count => 5, group_values => [] }),
                $Group->new({ count => 7, group_values => [] }),
            ],
        }));
    };

    my $result =
        $client->count_workflows('WorkflowType="Foo" GROUP BY ExecutionStatus')->get;
    T2->is($result->{count}, 12, 'count is the sum across groups');
    T2->is(scalar(@{ $result->{groups} }), 2, 'both aggregation buckets present');
    T2->is($result->{groups}[0]->count, 5, 'first bucket count');
    T2->is($result->{groups}[1]->count, 7, 'second bucket count');
});

T2->done_testing;
