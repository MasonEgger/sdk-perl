# ABOUTME: Fixture workflow whose :Update handlers fail post-acceptance — one
# ABOUTME: throws a Temporal failure (rejected), one plain dies (workflow task
# ABOUTME: failure) — driving T-upd-5/6 in updates.t. The :Run parks on a timer.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

# Both handlers have NO validator, so they are accepted unconditionally, then
# fail in the handler body. `appFail` throws a Temporalio::Exception::Application
# (a Temporal failure type) -> UpdateResponse.rejected post-acceptance, workflow
# unaffected. `plainDie` does a bare die -> a workflow task failure (the whole
# activation fails), NOT an update rejection.
class WfDef::FailingUpdater :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        await Temporalio::Workflow::sleep(3600);
        return 'ok';
    }

    method app_fail :Update('appFail') ($) {
        Temporalio::Exception::Application->throw(
            message => 'handler boom',
            type    => 'HandlerBoom',
        );
    }

    method plain_die :Update('plainDie') ($) {
        die "plain boom\n";
    }
}

1;
