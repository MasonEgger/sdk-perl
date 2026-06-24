# ABOUTME: Fixture workflow that upserts search attributes on each `upsert`
# ABOUTME: signal then completes on `done` — drives upsert.t SA replay cases.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Common::SearchAttributeKey;

# :Run upserts an initial keyword SA (value_set), then waits for `done`. Each
# `set` signal sets CustomKeywordField to a new value; each `clear` signal
# value_unsets it. This drives one-and-sequential upserts so info can be read
# back between activations (T-upsert-1..3).
class WfDef::SearchAttributeUpserter :isa(Temporalio::Workflow::Definition) {
    field $done = 0;

    async method run :Run () {
        my $key = Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField');
        Temporalio::Workflow::upsert_search_attributes($key->value_set('first'));
        await Temporalio::Workflow::wait_condition(sub { $done });
        return 'ok';
    }

    method set :Signal('set') ($value) {
        my $key = Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField');
        Temporalio::Workflow::upsert_search_attributes($key->value_set($value));
        return;
    }

    method clear :Signal('clear') () {
        my $key = Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField');
        Temporalio::Workflow::upsert_search_attributes($key->value_unset);
        return;
    }

    method finish :Signal('done') () {
        $done = 1;
        return;
    }
}

1;
