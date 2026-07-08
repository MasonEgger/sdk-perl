# ABOUTME: Fixture workflow whose :Run returns info->{memo}{reason} — drives
# ABOUTME: the inbound memo-decode assertion in codec_memo_headers.t (R7).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run reads the start-time memo view and returns the `reason` entry. The
# Runner seeds the view by from_payload-ing every memo field on the
# InitializeWorkflow job, so a memo payload still wearing the codec wrapper
# (i.e. NOT decoded at the worker boundary) dies in the payload converter
# instead of returning the value.
class WfDef::MemoEcho :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        return Temporalio::Workflow::info()->{memo}{reason};
    }
}

1;
