# ABOUTME: Fixture workflow that continues-as-new with typed search attributes
# ABOUTME: and a versioning_intent taken from its argument; drives
# ABOUTME: continue_as_new_options.t (spec R25, finding R11).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Common::SearchAttributeKey;
use Temporalio::Common::TypedSearchAttributes;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::CanWithOptions :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($intent = 'compatible') {
        my $sa = Temporalio::Common::TypedSearchAttributes->new([
            [ Temporalio::Common::SearchAttributeKey->keyword(
                  'CustomKeywordField') => 'can-sa' ],
        ]);
        Temporalio::Workflow::continue_as_new(
            'NextRun',
            args              => [1],
            search_attributes => $sa,
            versioning_intent => $intent,
        );
        return 'unreachable';
    }
}

1;
