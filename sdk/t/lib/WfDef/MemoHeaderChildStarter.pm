# ABOUTME: Fixture workflow that starts a child carrying memo, headers, and a
# ABOUTME: search attribute — drives the outbound child-start codec asserts (R7).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Common::SearchAttributeKey ();
use Temporalio::Common::TypedSearchAttributes ();
use Temporalio::Converter::Payload;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts one child with a memo entry, an already-Payload header value
# (the HeaderActivityCaller precedent: deterministic, pure conversion), and a
# typed search attribute. codec_memo_headers.t asserts the emitted
# StartChildWorkflowExecution's memo and header payloads are codec-wrapped
# outbound while the search-attribute payload is NOT (the sdk-python
# skip_search_attributes exclusion).
class WfDef::MemoHeaderChildStarter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $pc = Temporalio::Converter::Payload->default;
        my $handle = await Temporalio::Workflow::start_child_workflow(
            'GreetingChild',
            id      => 'child-1',
            args    => ['child-arg'],
            memo    => { note => 'child-memo' },
            headers => { h_child => $pc->to_payload('child-header') },
            search_attributes => Temporalio::Common::TypedSearchAttributes->new([
                [ Temporalio::Common::SearchAttributeKey->keyword(
                    'CustomKeywordField') => 'child-sa' ],
            ]),
        );
        return $handle->first_execution_run_id;
    }
}

1;
