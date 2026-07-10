# ABOUTME: Fixture workflow whose :Run throws an Application error carrying a
# ABOUTME: details payload — drives the outbound arm of codec_failure_payloads.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

class WfDef::DetailedFailer :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        Temporalio::Exception::Application->throw(
            message => 'detailed boom',
            type    => 'DetailedError',
            details => ['secret-detail'],
        );
    }
}

1;
