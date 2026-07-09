# ABOUTME: Repro + regression for #10 C-ICEPT-HEADERS: the workflow-inbound
# ABOUTME: ExecuteWorkflow input the Runner builds must carry the start headers
# ABOUTME: from the InitializeWorkflow activation job, so the inbound interceptor
# ABOUTME: (e.g. context propagation) reads the real header instead of an empty map.
#
# Spec R70 / finding T10: this file is THE #10 C-ICEPT-HEADERS regression
# guard; the live integration twin (t/integration/repro_interceptor_headers.t)
# was deleted in the R70 conversion. The client-side half (start headers
# encoded onto the StartWorkflowExecution request) is offline-guarded by
# t/unit/start_workflow_request.t.
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

use Temporalio::Converter::Payload ();
use Temporalio::Worker::Interceptor ();
use Temporalio::Test::WorkflowReplay ();

# A workflow-inbound spy that records the execute_workflow input's `headers`
# map (the start headers the Runner threads in from InitializeWorkflow) before
# delegating to the next link. Signature-less methods + the explicit ->new call
# are required under `feature 'class'` + Future::AsyncAwait (see other inbound
# interceptor tests).
class HeaderSpyInbound :isa(Temporalio::Worker::WorkflowInbound) {
    field $seen :param;
    method execute_workflow {
        %$seen = ( $_[0]->headers // {} )->%*;
        return $self->next->execute_workflow($_[0]);
    }
}
class HeaderSpyInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $seen :param;
    method intercept_workflow {
        return HeaderSpyInbound->new(next => $_[0], seen => $seen);
    }
}

# Drive an InitializeWorkflow job carrying a non-empty `headers` map and assert
# the workflow-inbound execute_workflow input the Runner builds carries those
# start headers. Today the Runner builds the input with only type/args/_root,
# so the spy sees an empty header map and this FAILS (the documented #10 gap).
T2->subtest('workflow-inbound input carries the InitializeWorkflow start headers' => sub {
    my $PC = Temporalio::Converter::Payload->default;
    my %seen;

    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::InterceptorObserved',
        interceptors   => [ HeaderSpyInterceptor->new(seen => \%seen) ],
    );

    my $activation =
        'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    $harness->push_activation($activation->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'InterceptorObserved',
                arguments     => [],
                headers       => {
                    '_request_id' => $PC->to_payload('rid-abc-123'),
                },
            } },
        ],
    }));

    T2->ok(exists $seen{_request_id},
        'the inbound execute_workflow input carries the start header key');
    T2->is($PC->from_payload($seen{_request_id}), 'rid-abc-123',
        'the start header payload decodes to the value set at workflow start')
        if exists $seen{_request_id};
});

T2->done_testing;
