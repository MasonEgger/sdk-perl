# ABOUTME: Workflow-author entry point (spec section 10) — `use Temporalio::Workflow;`.
# ABOUTME: Loads the definition base so :isa(Temporalio::Workflow::Definition) resolves.
package Temporalio::Workflow;

use v5.38;
use warnings;

use Future::AsyncAwait;

# A user workflow module says `use Temporalio::Workflow;` and then declares
# `class My::Workflow :isa(Temporalio::Workflow::Definition)`. Loading the base
# here means the author does not have to `use` it separately, and the
# :Run/:Signal/:Query/:Update/:Init attribute handlers are in scope.
use Scalar::Util ();

use Temporalio::Workflow::Definition ();
use Temporalio::Workflow::ContinueAsNew ();
use Temporalio::Exception::Workflow::NoRunner ();

# The Temporalio::Workflow:: functional surface (spec section 10.2). Every
# function looks up the active runner via $Temporalio::Workflow::Runner::CURRENT,
# which the runner sets via Syntax::Keyword::Dynamically around the workflow
# body. Calling any of them outside a workflow body raises
# Temporalio::Exception::Workflow::NoRunner. The deterministic-execution
# functions land incrementally: replay-safety accessors (P3.3),
# execute_activity/start_activity (P3.4), start_timer/sleep (P3.5);
# continue_as_new and friends arrive in later phases.

# Internal: return the active runner or raise NoRunner. $CURRENT lives in the
# Temporalio::Workflow::Runner package; we read it by its fully-qualified name
# (no `use` of the runner here — it `use`s us via the definition base, and the
# runner sets $CURRENT before any body code can call these functions).
sub _runner {
    my $runner = $Temporalio::Workflow::Runner::CURRENT;
    return $runner if defined $runner;
    Temporalio::Exception::Workflow::NoRunner->throw(
        message => 'Temporalio::Workflow context function called outside a '
            . 'workflow body (no active runner)',
    );
}

# now -> a DateTime at the activation timestamp (never the OS clock).
sub now {
    require DateTime;
    return DateTime->from_epoch(epoch => _runner()->activation_time);
}

# time -> epoch seconds (float) of the activation timestamp.
sub time { return _runner()->activation_time }

# is_replaying -> true while applying replayed history.
sub is_replaying { return _runner()->is_replaying }

# random -> the deterministic RNG seeded from the activation's randomness_seed.
sub random { return _runner()->random }

# logger -> the replay-aware workflow logger (spec section 10.4). Its level
# methods (info/warn/error/...) emit only while not replaying so history
# re-application does not duplicate lines (T-wf-9); the is_* predicates always
# return true so user code can build messages regardless of replay state.
sub logger { return _runner()->logger }

# info -> the WorkflowInfo hashref (run_id, workflow_type, patches, ... grows in
# later phases as more fields are threaded through the activation).
sub info { return _runner()->info }

# --- versioning / patching (spec section 10.4) ------------------------------

# patched($patch_id) -> a boolean: should this run take the "with change"
# branch? On a fresh execution always true (and emits a SetPatchMarker); during
# replay true only when the server notified the patch (NotifyHasPatch). The
# answer is memoized per run so it is deterministic (MUST-match sdk-python
# workflow.patched).
sub patched ($patch_id) {
    return _runner()->patched($patch_id);
}

# deprecate_patch($patch_id) -> mark a patch as being removed (all future
# deployments will only have the "with change" code). Emits a SetPatchMarker
# with deprecated => 1 the first time it is used on a live run; the patched
# branch is then unconditional (MUST-match sdk-python workflow.deprecate_patch,
# which calls workflow_patch(id, deprecated=True)).
sub deprecate_patch ($patch_id) {
    return _runner()->patched($patch_id, deprecated => 1);
}

# --- activity invocation (spec section 10.2) --------------------------------

# Resolve the first positional argument of execute_activity/start_activity to
# an activity-type name string. Accepts a plain string (used verbatim), a
# Temporalio::Activity::FunctionDefinition (->name), or an activity definition
# class/object exposing _activity_type / activity_type. Mirrors the reference
# SDKs, which accept a name, a function, or a definition.
sub _activity_type_name ($activity) {
    if (Scalar::Util::blessed($activity)) {
        return $activity->name if $activity->can('name');
        return $activity->activity_type if $activity->can('activity_type');
    }
    # A plain string (the common case) is the activity type verbatim.
    return $activity;
}

# execute_activity($activity, %opts) -> Future of the activity result. Emits a
# ScheduleActivity command and returns the Workflow::Future the runner resolves
# from the matching ResolveActivity job. `await` it to get the result (or have
# the activity failure raised). %opts are the spec section 10.2 kwargs (args,
# the four timeouts, retry_policy, task_queue, activity_id, cancellation_type,
# headers, ...).
sub execute_activity ($activity, %opts) {
    return _runner()->schedule_activity(
        activity_type => _activity_type_name($activity),
        %opts,
    );
}

# start_activity($activity, %opts) -> the activity handle (a Workflow::Future).
# Same scheduling as execute_activity; returned without awaiting so the caller
# can start several activities concurrently before awaiting them. (The richer
# ActivityHandle surface — cancel, result — is a Workflow::Future today; it
# grows in a later phase.)
sub start_activity ($activity, %opts) {
    return _runner()->schedule_activity(
        activity_type => _activity_type_name($activity),
        %opts,
    );
}

# --- child workflows (spec section 18) --------------------------------------

# start_child_workflow($workflow, %opts) -> (async) the ChildWorkflowHandle,
# resolved once the child has STARTED. Unlike start_activity (which returns a
# Future synchronously), this is `async` and itself awaited: it suspends on the
# runner's start Future until ResolveChildWorkflowExecutionStart arrives, then
# resolves to the handle (mirrors sdk-python `await ..._start_fut`). The first
# positional resolves to a workflow-type name the same way continue_as_new does.
# %opts are the spec section 18.1 kwargs (args, id, task_queue,
# cancellation_type, parent_close_policy, id_reuse_policy, the three timeouts,
# retry_policy, cron_schedule, memo, search_attributes, headers).
async sub start_child_workflow ($workflow, %opts) {
    my $handle = await _runner()->start_child_workflow(
        workflow_type => _workflow_type_name($workflow),
        %opts,
    );
    return $handle;
}

# execute_child_workflow($workflow, %opts) -> (async) the child's return value.
# Sugar over start_child_workflow + ->result: awaits the start, then awaits the
# result. A result failure raises Temporalio::Exception::ChildWorkflow at this
# await site (spec section 18.3).
async sub execute_child_workflow ($workflow, %opts) {
    my $handle = await start_child_workflow($workflow, %opts);
    return await $handle->result;
}

# --- timers (spec section 10.2) ---------------------------------------------

# start_timer($seconds) -> a Workflow::Future that resolves when the timer
# fires. Emits a StartTimer command and returns without awaiting, so the caller
# may start several timers (or run other work) before awaiting. Cancelling the
# returned Future emits a CancelTimer command and raises
# Temporalio::Exception::Cancelled at the await site.
sub start_timer ($seconds) {
    return _runner()->start_timer($seconds);
}

# sleep($seconds) -> a Future that resolves after the timer fires. The
# documented alias over start_timer: sleep(duration) starts a timer and awaits
# it. Returning the Future (rather than awaiting here) keeps the await in the
# caller's async frame so the dynamically-scoped runner context is preserved
# across the suspension (spec section 16.1).
sub sleep ($seconds) {
    return _runner()->start_timer($seconds);
}

# --- wait_condition (spec section 10.2) -------------------------------------

# wait_condition($predicate, %opts) -> a Future that resolves once $predicate
# returns true. `await` it to suspend the workflow body until the condition
# holds. The predicate is re-checked after each activation is applied (a signal
# arrived, a timer fired, an activity resolved), so a flag set by a :Signal
# handler resumes the awaiting body in that same activation. The predicate MUST
# be deterministic and side-effect-free — it reads workflow state only and is
# re-run every pump (it must never command). %opts: timeout (seconds) races the
# wait against a timer; on timeout the awaited Future raises a
# Temporalio::Exception::Timeout (MUST-match sdk-python wait_condition over
# asyncio.wait_for). This is the core building block for "wait until a signal
# sets a flag" patterns (spec section 10.2 / T-wf-5).
sub wait_condition ($predicate, %opts) {
    return _runner()->wait_condition($predicate, %opts);
}

# --- handler completion gating (spec section 19.2) --------------------------

# all_handlers_finished -> true when no :Signal/:Update handler Future is still
# in-flight (MUST-match sdk-python workflow.all_handlers_finished). The
# recommended Temporal pattern is to gate :Run completion explicitly with
# `await wait_condition(\&Temporalio::Workflow::all_handlers_finished)` before
# returning, since the runner otherwise warns-and-completes (abandoning any
# in-flight handler).
sub all_handlers_finished {
    return _runner()->_all_handlers_finished;
}

# --- continue-as-new (spec section 10.2 / 10.3 step 6) ----------------------

# continue_as_new($workflow_or_string, %opts) — request that the current run
# end and a new run start with the given arguments. Like sdk-python's
# workflow.continue_as_new (which raises _ContinueAsNewError), this NEVER
# returns: it dies with a Temporalio::Workflow::ContinueAsNew control signal
# that unwinds the :Run coroutine. The runner catches it in its outcome
# decision table and emits a ContinueAsNewWorkflowExecution command.
#
# $workflow_or_string is the new workflow type (a name string, or a definition
# class/object resolved the same way as execute_activity's first argument).
# Pass undef to re-use the current workflow type. %opts mirror spec section
# 10.2: args (arrayref), task_queue, retry_policy, memo, search_attributes,
# headers, run_timeout / task_timeout (seconds), versioning_intent.
sub continue_as_new ($workflow_or_string = undef, %opts) {
    # Validate we are inside a workflow body (raises NoRunner otherwise) so a
    # stray call outside a run is a clear error rather than an uncaught die.
    _runner();

    my $type = defined $workflow_or_string
        ? _workflow_type_name($workflow_or_string)
        : undef;

    die Temporalio::Workflow::ContinueAsNew->new(
        (defined $type ? (workflow => $type) : ()),
        %opts,
    );
}

# Resolve a continue_as_new first argument to a workflow-type name string.
# Accepts a plain string (verbatim), a workflow definition class/object
# exposing _workflow_type / workflow_type, mirroring _activity_type_name.
sub _workflow_type_name ($workflow) {
    if (Scalar::Util::blessed($workflow)) {
        return $workflow->workflow_type if $workflow->can('workflow_type');
        return $workflow->_workflow_type if $workflow->can('_workflow_type');
    }
    if (!ref $workflow && $workflow->can('_workflow_type')) {
        return $workflow->_workflow_type;
    }
    # A plain string (the common case) is the workflow type verbatim.
    return $workflow;
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow - entry point for workflow authors

=head1 SYNOPSIS

    use feature 'class';
    use Future::AsyncAwait;
    use Temporalio::Workflow;

    class My::Workflow::Greeting :isa(Temporalio::Workflow::Definition) {
        async method run :Run ($name) {
            return "Hello, $name!";
        }
    }

=head1 DESCRIPTION

C<use Temporalio::Workflow;> in a workflow module loads
L<Temporalio::Workflow::Definition> so the C<:isa> base resolves and the
C<:Run>/C<:Signal>/C<:Query>/C<:Update>/C<:Init> attribute handlers are in
scope. It also provides the workflow-context functional surface (spec section
10.2): replay-safety accessors (C<now>, C<time>, C<is_replaying>, C<info>,
C<random>), activity invocation (C<execute_activity>, C<start_activity>),
timers (C<start_timer>, C<sleep>), C<wait_condition> (suspend the body until a
predicate holds, optionally with a timeout), and C<continue_as_new>. Each looks
up the active runner and raises L<Temporalio::Exception::Workflow::NoRunner> when
called outside a workflow body.

=head1 METHODS

=head2 all_handlers_finished

Returns true when no C<:Signal>/C<:Update> handler is still in-flight. The
recommended pattern is to gate C<:Run> completion with
C<< await wait_condition(\&Temporalio::Workflow::all_handlers_finished) >>; the
runner otherwise warns and completes, abandoning any in-flight handler.

=head2 continue_as_new

Ends the current run and continues the workflow as a new execution with the given arguments/options.

=head2 deprecate_patch

Marks a patch id as deprecated, recording a deprecation marker so the branch can later be removed.

=head2 execute_activity

Async. Schedules an activity and awaits its result, returning an awaitable resolving to the activity's return value.

=head2 execute_child_workflow

Async. Starts a child workflow and awaits its result, returning an awaitable resolving to the child's return value (or raising L<Temporalio::Exception::ChildWorkflow> on failure).

=head2 start_child_workflow

Async. Starts a child workflow and awaits its start, returning an awaitable resolving to the L<Temporalio::Workflow::ChildWorkflowHandle> once the child has started.

=head2 info

Returns the L<Temporalio::Workflow::Info> for the running workflow.

=head2 is_replaying

Returns true while the workflow is replaying history.

=head2 logger

Returns the replay-aware L<Temporalio::Workflow::Logger> for the running workflow.

=head2 now

Returns the deterministic current time as a L<DateTime> at the activation timestamp (never the OS clock).

=head2 patched

Returns true if the given patch id is active, recording a patch marker for deterministic versioning.

=head2 random

Returns the workflow's deterministic RNG (seeded from the activation randomness seed).

=head2 sleep

Async. Durably sleeps for the given duration via a workflow timer; returns an awaitable that resolves when the timer fires.

=head2 start_activity

Schedules an activity and returns its awaitable handle without awaiting it.

=head2 start_timer

Starts a workflow timer for the given duration and returns its awaitable without awaiting it.

=head2 time

Returns the deterministic current time as epoch seconds at the activation timestamp.

=head2 wait_condition

Async. Suspends until the given predicate becomes true (re-checked on each activation), with an optional timeout.

=cut
