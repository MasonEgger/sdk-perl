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
# surface spans the replay-safety accessors, execute_activity/start_activity,
# start_timer/sleep, continue_as_new, and the v0.2 additions (child
# workflows, updates, external handles, memo/search-attribute upserts).

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
#
# now/time/random are the deterministic primitives the determinism guard must
# NEVER trap (the self-exemption contract, T-det-4 / spec §29.4). time and random
# read the runner directly and touch no builtin, so they are naturally exempt.
# now is the exception: DateTime->from_epoch decomposes the epoch into calendar
# fields via the `gmtime` builtin, which the guard's CORE::GLOBAL::gmtime override
# traps as non-determinism, so a workflow body that calls now (e.g. the
# updatable-timer loop's `now->epoch`) task-fails every activation under a LIVE
# worker and wedges, even though the epoch is the deterministic activation time
# and the decomposition is provably safe (bug #4, B10 C-COND-TIMEOUT). Construct
# the DateTime under the guard-suppression hatch so now honors the same
# self-exemption time and random already enjoy. The block is fully synchronous
# (no await), and Unsafe::illegal_call_tracing_disabled scopes the suppression
# to it, so the guard re-engages the instant now returns.
sub now {
    require DateTime;
    require Temporalio::Workflow::Unsafe;
    my $epoch = _runner()->activation_time;
    return Temporalio::Workflow::Unsafe::illegal_call_tracing_disabled(
        sub { DateTime->from_epoch(epoch => $epoch) });
}

# time -> epoch seconds (float) of the activation timestamp.
sub time { return _runner()->activation_time }

# is_replaying -> true while applying replayed history.
sub is_replaying { return _runner()->is_replaying }

# random -> the deterministic RNG seeded from the activation's randomness_seed.
sub random { return _runner()->random }

# uuid4 -> a determinism-safe v4 UUID string drawn from the SAME deterministic
# RNG that random() returns (never a fresh generator, never OS entropy), so the
# value is stable across replay and re-seeds with UpdateRandomSeed. Parity
# audit, in-workflow finding 1 (spec R77); MUST-match sdk-python
# workflow/_context.py:866, which draws getrandbits(16 * 8) big-endian from the
# seeded RNG and stamps version 4: four 32-bit ISAAC draws packed big-endian
# are the same 128 RNG bits, then the version nibble is forced to 4 and the
# variant bits to RFC 4122 10xx exactly as uuid.UUID(version=4) does. Like
# random, this touches no builtin, so the determinism guard's self-exemption
# contract (T-det-4 / spec section 29.4) holds naturally. Not cryptographically
# safe; do not use for security purposes.
sub uuid4 {
    my $rng   = _runner()->random;
    my @bytes = unpack('C16', pack('N4', map { $rng->irand } 1 .. 4));
    $bytes[6] = ($bytes[6] & 0x0f) | 0x40;    # version nibble -> 4
    $bytes[8] = ($bytes[8] & 0x3f) | 0x80;    # variant bits -> RFC 4122 10xx
    return sprintf(
        '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x',
        @bytes);
}

# logger -> the replay-aware workflow logger (spec section 10.4). Its level
# methods (info/warn/error/...) emit only while not replaying so history
# re-application does not duplicate lines (T-wf-9); the is_* predicates always
# return true so user code can build messages regardless of replay state.
sub logger { return _runner()->logger }

# metric_meter -> the replay-safe workflow metric meter (spec R83): a
# Temporalio::Runtime::MetricMeter::Meter carrying the workflow attribute set
# (namespace, task_queue, workflow_type) whose instruments no-op while the
# activation replays (Python parity: workflow/_context.py:710).
sub metric_meter { return _runner()->metric_meter }

# info -> the workflow info hashref (workflow_id, run_id, workflow_type,
# namespace, task_queue, attempt, patches, search_attributes, memo; spec R36,
# Python-parity field names).
sub info { return _runner()->info }

# The dynamic per-activation info accessors (spec R79; parity audit,
# in-workflow finding 3): the values the current activation delivered, updated
# each workflow task. Python surfaces these as METHODS on workflow.info()'s
# Info object (workflow/_context.py:140-185) precisely because they must read
# live per-activation state; the Perl info() is a plain hashref, so the
# equivalent live readers are these package functions, a documented spec
# section 0 surface deviation.
sub get_current_history_length { return _runner()->get_current_history_length }

sub get_current_history_size { return _runner()->get_current_history_size }

sub get_current_build_id { return _runner()->get_current_build_id }

sub is_continue_as_new_suggested {
    return _runner()->is_continue_as_new_suggested;
}

# memo / search_attributes -> the current in-workflow views as fresh copies,
# including upserted changes (spec R54 / finding A6; the archived v1 spec
# promised both readers at lines 1869-1870 and they fell out of the v0.1 scope
# cut). Shapes match sdk-python: memo() is workflow.memo()'s name -> converted-
# value mapping; search_attributes() is the info search-attribute view kept in
# sync by upsert_search_attributes.
sub memo { return _runner()->memo }

sub search_attributes { return _runner()->search_attributes }

# --- last-run carry-over (spec R88) ------------------------------------------

# has_last_completion_result / get_last_completion_result / get_last_failure ->
# the previous run's completion result and failure for cron and scheduled
# workflows (spec R88; parity audit, in-workflow finding 7; MUST-match
# sdk-python workflow.has_last_completion_result / get_last_completion_result /
# get_last_failure, workflow/_context.py:675,688,696). All three are callable
# as package functions or as class methods; each drops a leading class
# argument, so no signatures on the hint-taking getter. Sourced from the
# InitializeWorkflow job's last_completion_result / continued_failure and
# decoded lazily on first access (finding 7). Outside a workflow body ->
# NoRunner.

sub has_last_completion_result {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    return _runner()->workflow_has_last_completion_result;
}

sub get_last_completion_result {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($type_hint) = @_;
    return _runner()->workflow_last_completion_result($type_hint);
}

sub get_last_failure {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    return _runner()->workflow_last_failure;
}

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
# priority, summary, headers, ...); priority and summary reach the emitted
# command per spec R69 / finding A17 (Python parity).
sub execute_activity ($activity, %opts) {
    return _runner()->schedule_activity(
        activity_type => _activity_type_name($activity),
        %opts,
    );
}

# start_activity($activity, %opts) -> the activity handle (a Workflow::Future).
# Same scheduling as execute_activity; returned without awaiting so the caller
# can start several activities concurrently before awaiting them. (The handle
# is a Workflow::Future: await it for the result, ->cancel it to request
# activity cancellation.)
sub start_activity ($activity, %opts) {
    return _runner()->schedule_activity(
        activity_type => _activity_type_name($activity),
        %opts,
    );
}

# --- local activities (spec section 21) -------------------------------------

# execute_local_activity($activity, %opts) -> Future of the activity result. The
# local-activity analog of execute_activity: emits a ScheduleLocalActivity
# command (core runs the activity in-process during the workflow task, with no
# server round-trip) and returns the Workflow::Future the runner resolves from
# the matching ResolveActivity job. `await` it for the result (or to have the
# terminal activity failure raised). %opts are the spec section 21.1 kwargs:
# args, schedule_to_close_timeout, schedule_to_start_timeout,
# start_to_close_timeout (seconds), retry_policy, local_retry_threshold
# (seconds, default 60), cancellation_type (default try_cancel), activity_id,
# summary, headers. At least one of start_to_close / schedule_to_close MUST be
# set. The backoff -> server-timer retry loop is runner-owned: the returned
# Future is a single stable outer future, resolved only on a terminal outcome.
sub execute_local_activity ($activity, %opts) {
    return _runner()->schedule_local_activity(
        activity_type => _activity_type_name($activity),
        %opts,
    );
}

# start_local_activity($activity, %opts) -> the activity handle (a
# Workflow::Future). Same scheduling as execute_local_activity; returned without
# awaiting so the caller may start several LAs concurrently before awaiting them.
sub start_local_activity ($activity, %opts) {
    return _runner()->schedule_local_activity(
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

# --- external workflow handles (spec section 20) ----------------------------

# get_external_workflow_handle($workflow_id, %opts) -> a
# Temporalio::Workflow::ExternalWorkflowHandle for an arbitrary already-running
# workflow in the current namespace. A SYNCHRONOUS, non-command constructor: it
# captures the id/run_id plus the runner reference and emits nothing (mirrors
# the reference SDKs' plain constructors). The handle's ->signal / ->cancel emit
# SignalExternalWorkflowExecution / RequestCancelExternalWorkflowExecution
# through the command stream (never client RPCs). %opts: run_id (undef targets
# the most recent run). Raises Temporalio::Exception::Workflow::NoRunner outside
# a workflow body.
sub get_external_workflow_handle ($workflow_id, %opts) {
    return _runner()->get_external_workflow_handle($workflow_id, %opts);
}

# --- Nexus (spec section 26) ------------------------------------------------

# create_nexus_client(endpoint => $endpoint, service => $service) -> a
# Temporalio::Workflow::NexusClient bound to that endpoint + service (spec
# section 26.1). A SYNCHRONOUS, non-command constructor: it captures the
# endpoint/service plus the runner reference and emits nothing (mirrors
# get_external_workflow_handle). The returned client's start_operation /
# execute_operation emit the ScheduleNexusOperation command through the runner.
# The endpoint is a plain string naming a server/operator-managed registry entry
# — there is no client-side endpoint creation (F4). Raises
# Temporalio::Exception::Workflow::NoRunner outside a workflow body.
sub create_nexus_client (%opts) {
    return _runner()->create_nexus_client(%opts);
}

# --- timers (spec section 10.2) ---------------------------------------------

# start_timer($seconds, %opts) -> a Workflow::Future that resolves when the
# timer fires. Emits a StartTimer command and returns without awaiting, so the
# caller may start several timers (or run other work) before awaiting.
# Cancelling the returned Future emits a CancelTimer command and raises
# Temporalio::Exception::Cancelled at the await site. %opts: summary, a
# single-line fixed summary for the timer that may appear in UI/CLI, carried
# on the command's user_metadata (spec R78 / in-workflow finding 2; MUST-match
# sdk-python workflow/_context.py:878).
sub start_timer ($seconds, %opts) {
    return _runner()->start_timer($seconds, %opts);
}

# sleep($seconds, %opts) -> a Future that resolves after the timer fires. The
# documented alias over start_timer: sleep(duration) starts a timer and awaits
# it. Returning the Future (rather than awaiting here) keeps the await in the
# caller's async frame so the dynamically-scoped runner context is preserved
# across the suspension (spec section 16.1). %opts: summary, as start_timer
# (MUST-match sdk-python workflow.sleep(duration, summary=...)).
sub sleep ($seconds, %opts) {
    return _runner()->start_timer($seconds, %opts);
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
# asyncio.wait_for). timeout_summary labels the backing timeout timer's
# StartTimer user_metadata (spec R78 / in-workflow finding 2; MUST-match
# sdk-python workflow/_context.py:894). This is the core building block for
# "wait until a signal sets a flag" patterns (spec section 10.2 / T-wf-5).
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

# --- runtime handler registration (spec R86) ---------------------------------

# The runtime set_*_handler / get_*_handler surface (spec R86; parity audit,
# in-workflow finding 4; MUST-match sdk-python workflow/_workflow_ops.py:833-985).
# Each setter installs, replaces, or (with an undef handler) removes a handler
# on the RUNNING instance, overriding any :Signal/:Query/:Update attribute
# handler of the same name; installing a signal handler immediately drains any
# buffered signals it now covers. Getters return the handler installed for
# EXACTLY that name (never the dynamic catch-all): the exact coderef for a
# runtime handler, an instance-bound closure for an attribute handler. All
# twelve are callable as package functions or as class methods
# (Temporalio::Workflow->set_signal_handler(...)); each drops a leading class
# argument, so no signatures here. Outside a workflow body -> NoRunner; a
# setter inside a read-only context (query handler, update validator) raises
# Temporalio::Exception::ReadOnly.

sub set_signal_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($name, $handler) = @_;
    return _runner()->workflow_set_signal_handler($name, $handler);
}

sub get_signal_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($name) = @_;
    return _runner()->workflow_get_signal_handler($name);
}

sub set_dynamic_signal_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($handler) = @_;
    return _runner()->workflow_set_signal_handler(undef, $handler);
}

sub get_dynamic_signal_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    return _runner()->workflow_get_signal_handler(undef);
}

sub set_query_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($name, $handler) = @_;
    return _runner()->workflow_set_query_handler($name, $handler);
}

sub get_query_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($name) = @_;
    return _runner()->workflow_get_query_handler($name);
}

sub set_dynamic_query_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($handler) = @_;
    return _runner()->workflow_set_query_handler(undef, $handler);
}

sub get_dynamic_query_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    return _runner()->workflow_get_query_handler(undef);
}

# set_update_handler($name, $handler, validator => $code) — the optional
# validator mirrors Python's keyword-only validator argument; it runs
# synchronously in a read-only context before acceptance. Omitting it removes
# any previous validator for the name (the new definition replaces the old
# wholesale, as Python's does).
sub set_update_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($name, $handler, %opts) = @_;
    return _runner()->workflow_set_update_handler(
        $name, $handler, $opts{validator});
}

sub get_update_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($name) = @_;
    return _runner()->workflow_get_update_handler($name);
}

sub set_dynamic_update_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    my ($handler, %opts) = @_;
    return _runner()->workflow_set_update_handler(
        undef, $handler, $opts{validator});
}

sub get_dynamic_update_handler {
    shift if @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;
    return _runner()->workflow_get_update_handler(undef);
}

# --- upsert search attributes & memo (spec section 24) ----------------------

# upsert_search_attributes(@updates) -> emit UpsertWorkflowSearchAttributes (spec
# section 24). @updates are Temporalio::Common::SearchAttributeUpdate objects
# built via $key->value_set($v) / $key->value_unset on a typed
# Temporalio::Common::SearchAttributeKey (the typed-only surface — adopting
# sdk-ruby; the Python-deprecated untyped-dict form is rejected with
# Temporalio::Exception::Argument by the runner). Empty @updates early-return with
# no command. Pre-converts before buffering, so a conversion failure leaves no
# partial command. Outside a workflow body -> NoRunner.
sub upsert_search_attributes (@updates) {
    return _runner()->upsert_search_attributes(@updates);
}

# upsert_memo(\%updates) -> emit ModifyWorkflowProperties (spec section 24).
# %updates is a name -> value hashref; an undef value REMOVES that key (a proper
# empty/null Payload — the deletion convention). Removals are emitted even for
# absent keys. Empty %updates early-return with no command. Pre-converts before
# buffering, so a conversion failure leaves no partial command. Outside a workflow
# body -> NoRunner.
sub upsert_memo ($updates) {
    return _runner()->upsert_memo($updates);
}

# --- continue-as-new (spec section 10.2 / 10.3 step 6) ----------------------

# continue_as_new($workflow_or_string, %opts) — request that the current run
# end and a new run start with the given arguments. Like sdk-python's
# workflow.continue_as_new (which raises _ContinueAsNewError), this NEVER
# returns: the runner routes the request through the workflow-outbound
# interceptor chain (spec R71), whose root dies with a
# Temporalio::Workflow::ContinueAsNew control signal that unwinds the :Run
# coroutine. The runner catches it in its outcome decision table and emits a
# ContinueAsNewWorkflowExecution command.
#
# $workflow_or_string is the new workflow type (a name string, or a definition
# class/object resolved the same way as execute_activity's first argument).
# Pass undef to re-use the current workflow type. %opts mirror spec section
# 10.2: args (arrayref), task_queue, retry_policy, memo, search_attributes,
# headers, run_timeout / task_timeout (seconds), versioning_intent.
sub continue_as_new ($workflow_or_string = undef, %opts) {
    my $type = defined $workflow_or_string
        ? _workflow_type_name($workflow_or_string)
        : undef;

    # _runner() validates we are inside a workflow body (raises NoRunner
    # otherwise) so a stray call outside a run is a clear error.
    _runner()->continue_as_new(
        (defined $type ? (workflow => $type) : ()),
        %opts,
    );
}

# Resolve a start_child_workflow / continue_as_new first argument to a
# workflow-type name string. Accepts a plain string (verbatim), a workflow
# definition class/object, or a workflow function ref. Resolution is
# single-sourced in the definition side's resolve_workflow_type (spec R63,
# finding A8: the client's start_workflow shares it); an unresolvable
# argument falls through unchanged, preserving the pre-R63 behavior here.
sub _workflow_type_name ($workflow) {
    return Temporalio::Workflow::Definition::resolve_workflow_type($workflow)
        // $workflow;
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

=head1 RAISING ERRORS FROM WORKFLOW CODE

How you fail a workflow task matters. A plain C<die> (or any uncaught
exception that is not a Temporal application error) is treated as a transient
workflow-task failure: the task is retried indefinitely until it succeeds or
the workflow times out. That is correct for a genuinely transient fault (a bug
you are about to fix, a momentary glitch), because it lets the workflow recover
once the cause is gone. It is the wrong behavior for a business or validation
error that will never succeed on retry: the workflow wedges, retrying the same
losing task forever.

For business and validation failures, raise
L<Temporalio::Exception::Application> instead, and set
C<< non_retryable => 1 >> when the condition will never clear on its own:

  use Temporalio::Exception::Application;

  Temporalio::Exception::Application->throw(
      message       => 'menu choice is required',
      non_retryable => 1,
  );

A non-retryable application error fails the workflow execution promptly with a
clear, typed reason instead of looping on retried workflow tasks. This is the
lesson from the activity-choice sample: a plain C<die> in the workflow body
turned a should-fail-fast validation error into a retryable task failure that
spun for the duration of the run.

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
Options include a C<priority> (a L<Temporalio::Common::Priority>, carried to the ScheduleActivity command's C<priority> field) and a C<summary> string (carried to the command's C<user_metadata.summary> Payload), matching Python (spec R69 / finding A17).

=head2 execute_child_workflow

Async. Starts a child workflow and awaits its result, returning an awaitable resolving to the child's return value (or raising L<Temporalio::Exception::ChildWorkflow> on failure).

=head2 execute_local_activity

Schedules a local activity (run in-process by core during the workflow task, with no server round-trip) and returns its awaitable handle (spec section 21). Await it for the activity's return value, or to have the terminal failure raised. The backoff-to-server-timer retry loop is runner-owned, so the returned handle is a single stable future resolved only on a terminal outcome.

=head2 start_local_activity

Schedules a local activity and returns its awaitable handle without awaiting it, so several local activities can run concurrently before being awaited (spec section 21).

=head2 start_child_workflow

Async. Starts a child workflow and awaits its start, returning an awaitable resolving to the L<Temporalio::Workflow::ChildWorkflowHandle> once the child has started.

=head2 get_external_workflow_handle

Returns a L<Temporalio::Workflow::ExternalWorkflowHandle> for an arbitrary
running workflow by id in the current namespace (spec section 20). A
synchronous, non-command constructor; the handle's C<signal>/C<cancel> emit
commands through the stream. Raises
L<Temporalio::Exception::Workflow::NoRunner> outside a workflow body.

=head2 create_nexus_client

C<create_nexus_client(endpoint =E<gt> $endpoint, service =E<gt> $service)>
returns a L<Temporalio::Workflow::NexusClient> bound to that Nexus endpoint and
service (spec section 26.1). A synchronous, non-command constructor; the client's
C<start_operation>/C<execute_operation> emit a C<ScheduleNexusOperation> command
through the stream. Raises L<Temporalio::Exception::Workflow::NoRunner> outside a
workflow body.

=head2 has_last_completion_result

Returns true when the previous run of this workflow (a cron or scheduled
run, or a continued run) carried over a completion result on the
initializing activation, false otherwise (spec R88; matches Python's
C<workflow.has_last_completion_result()>). Differentiates "no previous
completion" from "the previous result was C<undef>" for
C<get_last_completion_result>. Callable as a package function or a class
method. Raises L<Temporalio::Exception::Workflow::NoRunner> outside a
workflow body.

=head2 get_last_completion_result

C<get_last_completion_result($type_hint = undef)> returns the previous run's
completion result, decoded through the payload converter with the optional
type hint forwarded to C<from_payload> (spec R88; matches Python's
C<workflow.get_last_completion_result()>). Returns C<undef> when there was
no previous completion OR the previous result was C<undef>;
C<has_last_completion_result> differentiates. A multi-payload previous
result warns and returns C<undef> (Python parity). Decoded lazily on first
access. Callable as a package function or a class method. Raises
L<Temporalio::Exception::Workflow::NoRunner> outside a workflow body.

=head2 get_last_failure

Returns the previous run's failure as a typed C<Temporalio::Exception::*>
object via the failure converter, or C<undef> when the workflow has not run
before or the previous run did not fail (spec R88; matches Python's
C<workflow.get_last_failure()>). Converted lazily on first access and cached
for the run. Callable as a package function or a class method. Raises
L<Temporalio::Exception::Workflow::NoRunner> outside a workflow body.

=head2 get_current_build_id

Returns the build id of the worker that processed the current workflow task,
or the empty string when that worker had none (spec R79; matches Python's
C<Info.get_current_build_id()>). Updated each activation; deterministic and
safe to branch on.

=head2 get_current_history_length

Returns the current number of events in history, as of the activation being
processed (spec R79; matches Python's C<Info.get_current_history_length()>).
Updated each activation; with C<get_current_history_size> and
C<is_continue_as_new_suggested>, the input for gating C<continue_as_new> on
history growth.

=head2 get_current_history_size

Returns the current history size in bytes, as of the activation being
processed (spec R79; matches Python's C<Info.get_current_history_size()>).
Updated each activation.

=head2 info

Returns the workflow info hashref for the running workflow: C<workflow_id>,
C<run_id>, C<workflow_type>, C<namespace>, C<task_queue>, C<attempt>,
C<patches>, C<search_attributes>, and C<memo> (spec R36; field names match
Python's C<workflow.info()>). A fresh copy per call. The dynamic
per-activation values are deliberately NOT in this hashref; read them through
C<get_current_history_length>, C<get_current_history_size>,
C<get_current_build_id>, and C<is_continue_as_new_suggested>, which stay
current across activations.

=head2 is_continue_as_new_suggested

Returns true when the server suggested continue-as-new on the current workflow
task (spec R79; matches Python's C<Info.is_continue_as_new_suggested()>).
Updated each activation.

=head2 is_replaying

Returns true while the workflow is replaying history.

=head2 logger

Returns the replay-aware L<Temporalio::Workflow::Logger> for the running workflow.

=head2 metric_meter

    Temporalio::Workflow::metric_meter()
        ->create_counter('my_counter', unit => 'widgets')
        ->add(1, { attr => 'value' });

Returns the replay-safe workflow metric meter (spec R83): a
L<Temporalio::Runtime::MetricMeter::Meter> backed by the worker runtime's
configured exporter and carrying the C<namespace>, C<task_queue>, and
C<workflow_type> attributes. Values recorded through it are B<suppressed
while the activation replays> (instruments are still created), matching
Python's C<workflow.metric_meter()>. Raises
L<Temporalio::Exception::Workflow::NoRunner> outside a workflow body.

=head2 memo

    my $memo = Temporalio::Workflow::memo();

Returns the current workflow memo as a name-to-converted-value hashref,
including changes applied by C<upsert_memo> (spec R54; matches Python's
C<workflow.memo()>). Seeded from the start-time memo on the initializing
activation. A fresh copy per call. Raises
L<Temporalio::Exception::Workflow::NoRunner> outside a workflow body.

=head2 now

Returns the deterministic current time as a L<DateTime> at the activation timestamp (never the OS clock).

=head2 patched

Returns true if the given patch id is active, recording a patch marker for deterministic versioning.

=head2 random

Returns the workflow's deterministic RNG (seeded from the activation randomness seed).

=head2 search_attributes

    my $sa = Temporalio::Workflow::search_attributes();

Returns the current workflow search attributes as a name-to-value hashref,
including changes applied by C<upsert_search_attributes> (spec R54; the same
view Python keeps in sync on C<workflow.info()>). Seeded from the start-time
search attributes on the initializing activation. A fresh copy per call.
Raises L<Temporalio::Exception::Workflow::NoRunner> outside a workflow body.

=head2 set_signal_handler

    Temporalio::Workflow->set_signal_handler('mySignal', sub (@args) { ... });
    Temporalio::Workflow->set_signal_handler('mySignal', undef);   # unset

Installs, replaces, or (with C<undef>) removes the signal handler for the
given name on the running instance (spec R86; matches Python's
C<workflow.set_signal_handler>). Overrides a C<:Signal> attribute handler of
the same name. On install, all buffered past signals for the name are
immediately sent to the new handler, in arrival order. The handler is a plain
coderef called with the decoded signal arguments (no instance argument); it
may be sync or async. Raises L<Temporalio::Exception::Workflow::NoRunner>
outside a workflow body and L<Temporalio::Exception::ReadOnly> inside a query
handler or update validator.

=head2 get_signal_handler

Returns the handler installed for exactly the given signal name, or C<undef>:
the exact coderef for a runtime-set handler, an instance-bound closure for a
C<:Signal> attribute handler. Never falls back to the dynamic handler
(matches Python's C<workflow.get_signal_handler>).

=head2 set_dynamic_signal_handler

Installs, replaces, or removes the dynamic (catch-all) signal handler. The
handler is called with C<($name, @args)>. On install, ALL buffered past
signals are immediately sent to it, in arrival order (matches Python's
C<workflow.set_dynamic_signal_handler>).

=head2 get_dynamic_signal_handler

Returns the installed dynamic signal handler, or C<undef>.

=head2 set_query_handler

Installs, replaces, or removes the query handler for the given name (spec
R86; matches Python's C<workflow.set_query_handler>). Overrides a C<:Query>
attribute handler of the same name. The handler runs in a read-only context,
like any query handler.

=head2 get_query_handler

Returns the handler installed for exactly the given query name, or C<undef>
(no dynamic fallback).

=head2 set_dynamic_query_handler

Installs, replaces, or removes the dynamic (catch-all) query handler, called
with C<($name, @args)>.

=head2 get_dynamic_query_handler

Returns the installed dynamic query handler, or C<undef>.

=head2 set_update_handler

    Temporalio::Workflow->set_update_handler('myUpdate', sub ($arg) { ... },
        validator => sub ($arg) { die "bad\n" unless ok($arg) });

Installs, replaces, or removes the update handler for the given name (spec
R86; matches Python's C<workflow.set_update_handler>). Overrides an
C<:Update> attribute handler of the same name. The optional C<validator> runs
synchronously in a read-only context before acceptance; omitting it removes
any previous validator for the name, and removing the handler removes its
validator too (the new definition replaces the old wholesale, as Python's
does).

=head2 get_update_handler

Returns the handler installed for exactly the given update name, or C<undef>
(no dynamic fallback).

=head2 set_dynamic_update_handler

Installs, replaces, or removes the dynamic (catch-all) update handler, called
with C<($name, @args)>. A C<validator> option is accepted for signature parity
with Python but is not consulted: the runner never validates a dynamic update
(there is no dynamic validator in this SDK's update dispatch).

=head2 get_dynamic_update_handler

Returns the installed dynamic update handler, or C<undef>.

=head2 sleep

Async. Durably sleeps for the given duration via a workflow timer; returns an awaitable that resolves when the timer fires.
An optional C<summary> (a single-line fixed summary that may appear in UI/CLI) is carried on the timer command's user metadata (spec R78).

=head2 start_activity

Schedules an activity and returns its awaitable handle without awaiting it.
Takes the same options as L</execute_activity>, including C<priority> and C<summary>.
The handle's C<cancel> honours the activity's C<cancellation_type>:
C<try_cancel> (the default) and C<abandon> resolve the handle Cancelled
immediately (C<abandon> without asking the server to cancel), while
C<wait_cancellation_completed> emits the cancel request and leaves the handle
pending until the activity's real resolution arrives, which may be a
successful completion if the activity ignores the cancel. The same contract
applies to C<start_local_activity> handles.

=head2 start_timer

Starts a workflow timer for the given duration and returns its awaitable without awaiting it.
Takes the same optional C<summary> as L</sleep>.

=head2 time

Returns the deterministic current time as epoch seconds at the activation timestamp.

=head2 upsert_search_attributes

    Temporalio::Workflow::upsert_search_attributes(@updates);

Emits an C<UpsertWorkflowSearchAttributes> command for the typed search-attribute
updates (spec section 24). C<@updates> are
L<Temporalio::Common::SearchAttributeUpdate> objects built via C<< $key->value_set($v) >>
/ C<< $key->value_unset >> on a typed L<Temporalio::Common::SearchAttributeKey>
(typed-only surface; an untyped mapping raises L<Temporalio::Exception::Argument>).
Empty updates early-return with no command. Values are converted before the
command is buffered, so a conversion failure leaves no partial command. Raises
L<Temporalio::Exception::Workflow::NoRunner> outside a workflow body.

=head2 upsert_memo

    Temporalio::Workflow::upsert_memo({ reason => 'x', stale => undef });

Emits a C<ModifyWorkflowProperties> command updating the workflow memo (spec
section 24). The hashref maps names to values; an C<undef> value removes that key
(a null Payload, the deletion convention) and is emitted even for an absent key.
Empty updates early-return with no command. Values are converted before the
command is buffered, so a conversion failure leaves no partial command. Raises
L<Temporalio::Exception::Workflow::NoRunner> outside a workflow body.

=head2 uuid4

    my $uuid = Temporalio::Workflow::uuid4();   # e.g. "9bcd6d3f-0a2f-4e8b-a1c4-..."

Returns a determinism-safe v4 UUID string (canonical lowercase 8-4-4-4-12
form) drawn from the same deterministic RNG C<random> returns (spec R77;
sdk-python C<workflow.uuid4>). Stable across replay of the same run; a second
call in the same run advances the RNG and yields a different value. Not
cryptographically safe; do not use for security purposes. Raises
L<Temporalio::Exception::Workflow::NoRunner> outside a workflow body.

=head2 wait_condition

Async. Suspends until the given predicate becomes true (re-checked on each activation), with an optional timeout.
An optional C<timeout_summary> labels the backing timeout timer's command user metadata (spec R78).

=cut
