# ABOUTME: Fixture workflow that snapshots Workflow::memo / ::search_attributes
# ABOUTME: before and after an upsert of both — drives workflow_memo_sa_readers.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Common::SearchAttributeKey;

# :Run reads both readers (the initializing-activation values), upserts a new
# SA value and a memo set+removal, reads both again, and returns the two
# snapshots as the workflow result so the test can decode them off the
# completion command. Also probes copy semantics: mutating a returned hashref
# must not leak into the runner's view (spec R54 / finding A6).
class WfDef::MemoSaReader :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $before = {
            memo              => Temporalio::Workflow::memo(),
            search_attributes => Temporalio::Workflow::search_attributes(),
        };

        # Copy-safety probe: poison the returned copies, then re-read.
        my $m_copy = Temporalio::Workflow::memo();
        $m_copy->{poison} = 1;
        my $sa_copy = Temporalio::Workflow::search_attributes();
        $sa_copy->{poison} = 1;
        my $leaked = (exists Temporalio::Workflow::memo()->{poison} ? 1 : 0)
                   + (exists Temporalio::Workflow::search_attributes()->{poison} ? 2 : 0);

        my $key = Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField');
        Temporalio::Workflow::upsert_search_attributes($key->value_set('updated'));
        Temporalio::Workflow::upsert_memo({ reason => 'updated', stale => undef });

        my $after = {
            memo              => Temporalio::Workflow::memo(),
            search_attributes => Temporalio::Workflow::search_attributes(),
        };
        return { before => $before, after => $after, leaked => $leaked };
    }
}

1;
