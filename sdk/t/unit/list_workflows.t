# ABOUTME: R64 (finding A9): list_workflows is synchronous (the iterator comes
# ABOUTME: back at once, no Future, no RPC) and each awaited ->next yields one
# ABOUTME: WorkflowExecutionInfo proto across lazily-fetched pages, then undef.
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

sub resolve { Temporalio::Core::Proto::resolve($_[0]) }

# The same per-object _rpc_call mock registry as client_option_strictness.t:
# a real Client whose RPC layer is a scripted handler, so no live connection
# is ever touched.
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
        namespace      => 'ns-test',
        identity       => 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

sub script ($client, @responders) {
    my @calls;
    my $i = 0;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request, opts => \%opts };
        my $r = $responders[$i++]
            // die "unexpected extra RPC call: $rpc\n";
        return Future->done($r->($rpc, $request, %opts));
    };
    return \@calls;
}

my $Response = resolve(
    'temporal.api.workflowservice.v1.ListWorkflowExecutionsResponse');
my $Info = resolve('temporal.api.workflow.v1.WorkflowExecutionInfo');
my $Exec = resolve('temporal.api.common.v1.WorkflowExecution');

sub an_info ($workflow_id) {
    return $Info->new({
        execution => $Exec->new({ workflow_id => $workflow_id }),
    });
}

T2->subtest('list_workflows is synchronous and pages lazily (R64)' => sub {
    my $client = make_client;
    my $calls  = script(
        $client,
        sub {
            return $Response->new({
                executions      => [ an_info('wf-1'), an_info('wf-2') ],
                next_page_token => 'tok-2',
            });
        },
        sub {
            return $Response->new({ executions => [ an_info('wf-3') ] });
        },
    );

    # The documented public contract (spec R64): the call itself is
    # synchronous. It returns the iterator at once, not a Future, and makes
    # no RPC until the first ->next is awaited.
    my $iter = $client->list_workflows('WorkflowType="T"', page_size => 2);
    T2->ok(Scalar::Util::blessed($iter), 'returns a blessed iterator object');
    T2->ok(!$iter->isa('Future'), 'the iterator is not a Future');
    T2->ok($iter->can('next'), 'the iterator has a next method');
    T2->is(scalar @$calls, 0, 'no RPC at call time');

    # next is async: it hands back a Future per element.
    my $first_future = $iter->next;
    T2->ok(
        Scalar::Util::blessed($first_future) && $first_future->isa('Future'),
        'next returns a Future');
    my $first = $first_future->get;
    T2->ok($first->isa($Info), 'next yields a WorkflowExecutionInfo proto');
    T2->is($first->execution->workflow_id, 'wf-1', 'first element');
    T2->is(scalar @$calls, 1, 'first next fetched exactly one page');

    T2->is($iter->next->get->execution->workflow_id, 'wf-2',
        'second element');
    T2->is(scalar @$calls, 1, 'second element served from the same page');

    T2->is($iter->next->get->execution->workflow_id, 'wf-3',
        'third element crosses the page boundary');
    T2->is(scalar @$calls, 2, 'page two fetched on demand');

    T2->is($iter->next->get, undef, 'exhausted iterator yields undef');
    T2->is(scalar @$calls, 2, 'exhaustion makes no extra RPC');

    # The paging plumbing under the contract.
    T2->is($calls->[0]{rpc}, 'ListWorkflowExecutions', 'RPC name');
    T2->is($calls->[0]{request}->namespace, 'ns-test',
        'request carries the client namespace');
    T2->is($calls->[0]{request}->query, 'WorkflowType="T"',
        'request carries the query');
    T2->is($calls->[0]{request}->page_size, 2, 'page_size threaded through');
    T2->is($calls->[1]{request}->next_page_token, 'tok-2',
        'second request carries the page token');
});

T2->done_testing;
