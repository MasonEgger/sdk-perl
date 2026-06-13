# ABOUTME: Workflow-author entry point (spec section 10) — `use Temporalio::Workflow;`.
# ABOUTME: Loads the definition base so :isa(Temporalio::Workflow::Definition) resolves.
package Temporalio::Workflow;

use v5.38;
use warnings;

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

# info -> the WorkflowInfo hashref (run_id, workflow_type, ... grows in later
# phases as more fields are threaded through the activation).
sub info { return _runner()->info }

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
timers (C<start_timer>, C<sleep>), and C<continue_as_new>. Each looks up the
active runner and raises L<Temporalio::Exception::Workflow::NoRunner> when
called outside a workflow body.

=cut
