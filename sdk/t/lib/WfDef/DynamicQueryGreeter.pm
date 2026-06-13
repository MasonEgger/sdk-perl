# ABOUTME: Fixture workflow with a dynamic catch-all :Query handler — drives the
# ABOUTME: dynamic-query fallback case (an unmatched query name routes to the
# ABOUTME: dynamic handler, called with (name, @args)) in queries.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# No named query handlers; a single dynamic catch-all (:Query(dynamic=1))
# receives every query as (name, @args) and echoes them back (mirrors
# sdk-python's dynamic query (name, args)). The :Run parks on a long timer so a
# query observes the in-flight workflow.
class WfDef::DynamicQueryGreeter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        await Temporalio::Workflow::sleep(3600);
        return 'done';
    }

    method any_query :Query(dynamic=1) ($name, @args) {
        return "$name=" . join('+', @args);
    }
}

1;
