# ABOUTME: Unit tests for the B13 (#11) Nexus async completion wiring: a
# ABOUTME: :WorkflowRunOperation backing-workflow start must carry the inbound
# ABOUTME: callback (so the server notifies the caller on completion), the Nexus
# ABOUTME: request_id, and the converted caller links. Deterministic and
# ABOUTME: server-free: a fake client captures what start_workflow receives.
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;

use Temporalio::Nexus::OperationContext ();
use Temporalio::Nexus::Link ();

sub await_f ($f) { return $f->get }

# A fake client that records the (\@args, %kwargs) start_workflow received and
# returns a handle whose workflow_id is fixed.
class FakeHandle { method workflow_id { return 'backing-wf-1' } }
class FakeClient {
    field $captured = undef;
    method captured  { return $captured }
    method namespace { return 'default' }
    method start_workflow ($workflow, $args = [], %kwargs) {
        $captured = { workflow => $workflow, args => $args, kwargs => { %kwargs } };
        return Future->done(FakeHandle->new);
    }
}

# A WorkflowEvent link the caller would send (a RequestIdReference to its own
# NexusOperationScheduled event).
my $WF_LINK_URL =
    'temporal:///namespaces/default/workflows/caller-wf/caller-run/history'
  . '?referenceType=RequestIdReference&requestID=req-abc'
  . '&eventType=NexusOperationScheduled';
my $WF_LINK_TYPE = 'temporal.api.common.v1.Link.WorkflowEvent';

T2->subtest('start_workflow attaches the Nexus completion callback (#11)' => sub {
    my $client = FakeClient->new;
    my $info   = Temporalio::Nexus::OperationInfo->new(
        service => 'svc', operation => 'op', task_queue => 'tq');
    my $ctx = Temporalio::Nexus::WorkflowRunOperationContext->new(
        info            => $info,
        client          => $client,
        callback        => 'http://caller/callback',
        callback_header => { 'x-trace' => 'abc' },
        request_id      => 'nexus-req-1',
        links           => [ { url => $WF_LINK_URL, type => $WF_LINK_TYPE } ],
    );

    my $handle = await_f($ctx->start_workflow('BackingWf', ['world'],
        id => 'wf-1', task_queue => 'tq'));
    T2->is($handle->workflow_id, 'backing-wf-1',
        'returns a Nexus WorkflowHandle for the backing workflow');

    my $kw = $client->captured->{kwargs};

    # The completion callback carries the caller's callback URL + header.
    my $cbs = $kw->{completion_callbacks};
    T2->ok($cbs && @$cbs == 1, 'one completion callback attached');
    my $nexus = $cbs->[0]->nexus;
    T2->is($nexus->url, 'http://caller/callback', 'callback URL threaded through');
    T2->is($nexus->header->{'x-trace'}, 'abc', 'callback header threaded through');

    # The Nexus request_id becomes the start idempotency key.
    T2->is($kw->{request_id}, 'nexus-req-1', 'Nexus request_id reused on the start');

    # The caller link is converted and attached to the start.
    my $links = $kw->{links};
    T2->ok($links && @$links == 1, 'one converted link attached to the start');
    T2->is($links->[0]->workflow_event->workflow_id, 'caller-wf',
        'the converted link references the caller workflow');
});

T2->subtest('no callback URL -> a plain start (no completion callback)' => sub {
    my $client = FakeClient->new;
    my $info   = Temporalio::Nexus::OperationInfo->new(
        service => 'svc', operation => 'op', task_queue => 'tq');
    # No inbound callback (e.g. a direct/test invocation).
    my $ctx = Temporalio::Nexus::WorkflowRunOperationContext->new(
        info => $info, client => $client);

    await_f($ctx->start_workflow('BackingWf', [], id => 'wf-2', task_queue => 'tq'));
    my $kw = $client->captured->{kwargs};
    T2->ok(!exists $kw->{completion_callbacks},
        'no completion_callbacks when there is no callback URL');
    T2->ok(!exists $kw->{links}, 'no links when there are none');
});

T2->subtest('nexus_link_to_temporal_link: workflow-event link' => sub {
    my $link = Temporalio::Nexus::Link::nexus_link_to_temporal_link(
        $WF_LINK_URL, $WF_LINK_TYPE);
    T2->ok(defined $link, 'a workflow link converts to a temporal link');
    my $we = $link->workflow_event;
    T2->is($we->namespace, 'default', 'namespace parsed');
    T2->is($we->workflow_id, 'caller-wf', 'workflow id parsed');
    T2->is($we->run_id, 'caller-run', 'run id parsed');
    T2->is($we->request_id_ref->request_id, 'req-abc',
        'request id reference parsed');
});

T2->subtest('nexus_link_to_temporal_link: unknown type / bad url -> undef' => sub {
    T2->ok(!defined Temporalio::Nexus::Link::nexus_link_to_temporal_link(
        'temporal:///nonsense', 'some.unknown.Type'),
        'an unknown link type yields undef (dropped, never breaks the start)');
    T2->ok(!defined Temporalio::Nexus::Link::nexus_link_to_temporal_link(
        'not a url at all', $WF_LINK_TYPE),
        'an unparseable workflow-link URL yields undef');
});

T2->done_testing;
