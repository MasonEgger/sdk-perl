# ABOUTME: Fixture workflow that continues-as-new with args, memo, and an
# ABOUTME: already-Payload header — drives codec_continue_as_new_args.t (R7).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Common::SearchAttributeKey;
use Temporalio::Common::TypedSearchAttributes;
use Temporalio::Converter::Payload;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::CanWithMemo :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($n = 1) {
        my $pc = Temporalio::Converter::Payload->default;
        Temporalio::Workflow::continue_as_new(
            'NextRun',
            args              => [ $n + 1 ],
            memo              => { note => 'can-memo' },
            headers           => { h_can => $pc->to_payload('can-header') },
            # Populated since spec R25; drives the SA-not-codec-wrapped
            # negative on the CAN surface.
            search_attributes => Temporalio::Common::TypedSearchAttributes->new([
                [ Temporalio::Common::SearchAttributeKey->keyword(
                      'CustomKeywordField') => 'can-sa' ],
            ]),
        );
        return 'unreachable';
    }
}

1;
