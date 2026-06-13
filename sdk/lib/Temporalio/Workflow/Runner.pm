# ABOUTME: The deterministic workflow Runner (spec section 10.3) — one instance
# ABOUTME: per workflow run. Applies activation jobs, drives the workflow body
# ABOUTME: via manually-resolved Futures (NEVER IO::Async), buffers commands.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Scalar::Util ();
use Syntax::Keyword::Dynamically;

use Temporalio::Workflow::Commands ();
use Temporalio::Workflow::Future ();
use Temporalio::Converter::Payload ();
use Temporalio::Converter::Failure ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Workflow::NoRunner ();

# The dynamically-scoped pointer to the currently-active runner. Every
# Temporalio::Workflow:: context function looks it up here (spec section 10.2).
# The runner sets it via `dynamically` around the workflow body so it is
# correctly torn down across an `await` (Future::AsyncAwait panics on `local`
# — spec section 16.1). It MUST live in the Temporalio::Workflow::Runner
# package (the functional surface reads $Temporalio::Workflow::Runner::CURRENT);
# this file has no leading `package` statement, so name the package explicitly
# for the declaration rather than relying on the ambient package being `main`.
package Temporalio::Workflow::Runner { our $CURRENT; }

# One instance per workflow run (cached by the dispatcher on run_id; the
# dispatcher cache itself lands in P3.6). Owns the workflow Definition
# instance, the deterministic RNG, the activation context (timestamp,
# is_replaying, run_id, workflow_type), the outbound command buffer, the
# pending-Futures map (populated by P3.4 activities / P3.5 timers), and the
# main run Future.
class Temporalio::Workflow::Runner {
    # The workflow type name and its backing Definition subclass (resolved by
    # the harness/dispatcher from the InitializeWorkflow job's workflow_type).
    field $workflow_class :param;
    field $run_id         :param = undef;

    # Payload converter for arguments (in) and the result (out). The replay
    # harness uses the default composite; a worker injects its data converter.
    field $payload_converter :param = undef;

    # Failure converter for ResolveActivity{failed/cancelled} job failures
    # (maps the Failure proto to a Temporalio::Exception::* at the await site).
    field $failure_converter :param = undef;

    # The workflow's own task queue — the default task queue for scheduled
    # activities when execute_activity/start_activity does not override it
    # (MUST-match sdk-python: ScheduleActivity.task_queue defaults to the
    # workflow execution's task queue). The replay harness leaves it undef.
    field $task_queue :param = undef;

    field $instance;                 # the workflow Definition instance
    field $workflow_type;            # resolved run type name
    field @commands;                 # outbound WorkflowCommand buffer
    field $main_run_future;          # the Future returned by :Run

    # Per-command-type sequence counters (spec section 10.3): each is
    # workflow-scoped, monotonic, starting at 1. Activities and timers allocate
    # from SEPARATE seq spaces (MUST-match sdk-python _next_seq("activity") vs
    # _next_seq("timer"); sdk-ruby @activity_counter vs @timer_counter), so a
    # workflow's first activity and first timer are both seq 1. Each is
    # matched on the corresponding ResolveActivity / FireTimer job.
    field $activity_seq_counter = 0;
    field $timer_seq_counter    = 0;

    # Pending activity Futures keyed by their command seq: { seq => $future }.
    # The Workflow::Future for each in-flight activity, resolved imperatively
    # when its ResolveActivity job arrives (P3.4). Child workflows (Phase 6+)
    # join analogous maps.
    field %pending_activities;

    # Pending timer Futures keyed by their StartTimer seq: { seq => $future }.
    # Resolved imperatively when the matching FireTimer job arrives (P3.5), or
    # removed and failed-as-cancelled when the timer Future is cancelled.
    field %pending_timers;

    # Activation context (set per activation; never the OS clock).
    field $activation_seconds = 0;
    field $activation_nanos   = 0;
    field $is_replaying       = 0;

    # Deterministic RNG state (seeded from the InitializeWorkflow job's
    # randomness_seed). See _make_rng below.
    field $rng;

    ADJUST {
        $payload_converter //= Temporalio::Converter::Payload->default;
        $failure_converter //= Temporalio::Converter::Failure->default;
        # Lazily load the workflow class if the caller has not already (the
        # replay harness accepts a class name without requiring it first).
        if (!$workflow_class->can('_workflow_type')) {
            my $path = ($workflow_class =~ s{::}{/}gr) . '.pm';
            require $path;
        }
        $workflow_type = $workflow_class->_workflow_type;
    }

    # --- context accessors read by the Temporalio::Workflow:: functions ------

    method run_id        { return $run_id }
    method workflow_type { return $workflow_type }
    method is_replaying  { return $is_replaying ? 1 : 0 }

    # Epoch seconds (float) of the activation timestamp.
    method activation_time {
        return $activation_seconds + ($activation_nanos / 1_000_000_000);
    }

    method random { return $rng }

    method info {
        return {
            run_id        => $run_id,
            workflow_type => $workflow_type,
        };
    }

    # --- activity scheduling (spec section 10.2 / 10.3) ----------------------

    # schedule_activity(%opts) -> a Temporalio::Workflow::Future resolved when
    # the matching ResolveActivity job arrives. Allocates the next seq, builds
    # the ScheduleActivity command, buffers it, and registers the pending
    # Future. The Workflow:: functional surface (execute_activity/start_activity)
    # delegates here. %opts mirrors the spec section 10.2 kwargs:
    #   activity_type (required), args (arrayref), task_queue, activity_id,
    #   schedule_to_close_timeout, schedule_to_start_timeout,
    #   start_to_close_timeout, heartbeat_timeout (all seconds), retry_policy
    #   (Temporalio::Common::RetryPolicy), cancellation_type (string), headers.
    method schedule_activity (%opts) {
        my $activity_type = $opts{activity_type}
            // die "Temporalio::Workflow::Runner: schedule_activity needs an "
                 . "activity_type";

        my $seq = ++$activity_seq_counter;  # activity seq space, from 1.

        # Convert the activity arguments to payloads (MUST-match sdk-python:
        # arguments converted before the command is built so a converter error
        # surfaces at the call site, not later).
        my @args = map { $payload_converter->to_payload($_) }
            (($opts{args} // [])->@*);

        my %fields = (
            seq           => $seq,
            # activity_id defaults to the seq as a string (sdk-python parity).
            activity_id   => (defined $opts{activity_id}
                ? $opts{activity_id} : "$seq"),
            activity_type => $activity_type,
            # task_queue defaults to the workflow's own queue (sdk-python parity);
            # the replay harness has no queue, so default to empty string.
            task_queue    => ($opts{task_queue} // $task_queue // ''),
            (@args ? (arguments => [@args]) : ()),
            # cancellation_type: spec string -> proto enum number (default
            # try_cancel = 0).
            cancellation_type =>
                _cancellation_type_number($opts{cancellation_type}),
        );

        # The four timeouts: seconds -> google.protobuf.Duration, only when set.
        for my $t (qw(schedule_to_close_timeout schedule_to_start_timeout
            start_to_close_timeout heartbeat_timeout))
        {
            next unless defined $opts{$t};
            $fields{$t} = _duration($opts{$t});
        }

        # Retry policy -> temporal.api.common.v1.RetryPolicy proto when given.
        if (defined(my $rp = $opts{retry_policy})) {
            $fields{retry_policy} = $rp->to_proto;
        }

        # Headers: { name => Perl value } -> { name => Payload } when non-empty.
        if (my $headers = $opts{headers}) {
            if (%$headers) {
                $fields{headers} = {
                    map { $_ => $payload_converter->to_payload($headers->{$_}) }
                        keys %$headers
                };
            }
        }

        push @commands,
            Temporalio::Workflow::Commands::schedule_activity(\%fields);

        # Register the pending Future the body awaits; the runner resolves it
        # imperatively from the ResolveActivity job (never via IO::Async).
        my $future = Temporalio::Workflow::Future->new;
        $pending_activities{$seq} = $future;
        return $future;
    }

    # --- timers (spec section 10.2 start_timer/sleep + 10.3 FireTimer) -------

    # start_timer($seconds) -> a Temporalio::Workflow::Future resolved when the
    # matching FireTimer job arrives. Allocates the next TIMER seq (a seq space
    # separate from activities — sdk-python _next_seq("timer") / sdk-ruby
    # @timer_counter), builds the StartTimer command, buffers it, and registers
    # the pending Future. Cancelling the returned Future emits a CancelTimer
    # command (same seq) and resolves the Future as Temporalio::Exception::
    # Cancelled (MUST-match sdk-ruby _apply_cancel_command / CanceledError).
    method start_timer ($seconds) {
        my $seq = ++$timer_seq_counter;   # timer seq space, from 1.

        push @commands, Temporalio::Workflow::Commands::start_timer({
            seq                   => $seq,
            start_to_fire_timeout => _duration($seconds),
        });

        # A timer future whose ->cancel FAILS the future with a
        # Temporalio::Exception::Cancelled (rather than putting it into Future's
        # native cancelled state). The reference SDKs raise a cancellation
        # *exception* into the awaiting frame (sdk-ruby fiber.raise(CanceledError);
        # sdk-python cancels the asyncio task which surfaces CancelledError) — a
        # natively-cancelled CPAN Future would instead make `await` throw a bare
        # "was cancelled" string, losing the Temporal exception identity. The
        # cancel also emits the CancelTimer command (same seq) and de-registers
        # the pending timer so a later FireTimer for it is a no-op.
        my $future = Temporalio::Workflow::Runner::_TimerFuture->_new_timer(
            seq        => $seq,
            on_cancel  => sub {
                return unless delete $pending_timers{$seq};
                push @commands,
                    Temporalio::Workflow::Commands::cancel_timer($seq);
            },
        );
        $pending_timers{$seq} = $future;
        return $future;
    }

    # --- activation processing (spec section 10.3) ---------------------------

    # process_activation($activation) -> the WorkflowActivationCompletion proto.
    method process_activation ($activation) {
        # Steps 1-2: activation context. (Step 3 job ordering + the full job
        # set land as later phases add job kinds; the skeleton handles
        # InitializeWorkflow and runs the body to completion.)
        $is_replaying = $activation->is_replaying ? 1 : 0;
        $run_id //= $activation->run_id;
        if (my $ts = $activation->timestamp) {
            $activation_seconds = $ts->seconds // 0;
            $activation_nanos   = $ts->nanos   // 0;
        }

        # The command buffer holds only THIS activation's commands: the worker
        # returns one completion per activation, so any commands emitted by a
        # prior activation have already been drained. The seq counter, by
        # contrast, is workflow-scoped and persists across activations.
        @commands = ();

        # Step 4: apply jobs under the dynamically-scoped runner context so the
        # workflow body's Temporalio::Workflow:: calls resolve to this runner.
        dynamically $Temporalio::Workflow::Runner::CURRENT = $self;
        for my $job ($activation->jobs->@*) {
            $self->_apply_job($job);
        }

        # Step 5: pump (drive ready continuations). The skeleton's only Future
        # is the main run Future, which Future::AsyncAwait resolves
        # synchronously for a body with no pending workflow Futures.
        $self->_pump;

        # Steps 6-7: drain the command buffer into a completion proto.
        return $self->_build_completion;
    }

    method _apply_job ($job) {
        my $variant = $job->which_variant // '';
        if ($variant eq 'initialize_workflow') {
            return $self->_apply_initialize($job->initialize_workflow);
        }
        if ($variant eq 'resolve_activity') {
            return $self->_apply_resolve_activity($job->resolve_activity);
        }
        if ($variant eq 'fire_timer') {
            return $self->_apply_fire_timer($job->fire_timer);
        }
        # SignalWorkflow / QueryWorkflow / CancelWorkflow / RemoveFromCache and
        # friends land in later phases.
        warn "Temporalio::Workflow::Runner: ignoring unhandled activation job"
           . " variant '$variant'\n";
        return;
    }

    method _apply_initialize ($init) {
        # Seed the deterministic RNG from the job (NOT the run id).
        $rng = _make_rng($init->randomness_seed // 0);

        # Convert the workflow arguments from payloads to Perl values.
        my @args = map { $payload_converter->from_payload($_) }
            ($init->arguments // [])->@*;

        # Instantiate the workflow class and kick off its :Run. The body runs
        # under the already-scoped $CURRENT (set in process_activation), so any
        # Temporalio::Workflow:: call inside it resolves to this runner. The
        # returned Future is pumped, not awaited synchronously.
        $instance = $workflow_class->new;
        my $run_ref = $workflow_class->_workflow_defs->{run};
        $main_run_future = $instance->$run_ref(@args);
        return;
    }

    # ResolveActivity { seq, result } — resolve the pending activity Future for
    # this seq (spec section 10.3; MUST-match sdk-python _apply_resolve_activity).
    # ActivityResolution.status is a oneof: completed -> ->done(decoded result);
    # failed/cancelled -> ->fail(exception mapped from the Failure proto). The
    # awaiting workflow continuation runs synchronously at resolve time
    # (Future::AsyncAwait on_ready), so progress is observed in the pump.
    method _apply_resolve_activity ($job) {
        my $seq    = $job->seq;
        my $future = delete $pending_activities{$seq};
        unless (defined $future) {
            # An unknown seq is a non-determinism signal (spec T-wf-13). The
            # full non-determinism policy is P3.5/P3.7; for now, fail loudly
            # rather than silently dropping the resolution.
            die "Temporalio::Workflow::Runner: ResolveActivity for unknown "
              . "seq $seq (no pending activity)";
        }

        my $resolution = $job->result;
        my $status     = defined $resolution ? $resolution->which_status : undef;
        $status //= '';

        if ($status eq 'completed') {
            my $success = $resolution->completed;
            my $payload = defined $success ? $success->result : undef;
            my $value   = defined $payload
                ? $payload_converter->from_payload($payload)
                : undef;
            $future->done($value);
        }
        elsif ($status eq 'failed') {
            my $failure = $resolution->failed->failure;
            $future->fail(
                $failure_converter->from_failure($failure, $payload_converter));
        }
        elsif ($status eq 'cancelled') {
            my $failure = $resolution->cancelled->failure;
            $future->fail(
                $failure_converter->from_failure($failure, $payload_converter));
        }
        else {
            die "Temporalio::Workflow::Runner: ResolveActivity seq $seq had no "
              . "recognized status (got '$status')";
        }
        return;
    }

    # FireTimer { seq } — resolve the pending timer Future for this seq (spec
    # section 10.3; MUST-match sdk-python _apply_fire_timer). An absent handle
    # is ignored, not an error: the timer may have been cancelled (and removed)
    # earlier in this same activation, in which case FireTimer is stale. The
    # awaiting workflow continuation runs synchronously at resolve time
    # (Future::AsyncAwait on_ready), so progress is observed in the pump.
    method _apply_fire_timer ($job) {
        my $seq    = $job->seq;
        my $future = delete $pending_timers{$seq};
        return unless defined $future;   # cancelled/removed: ignore stale fire.
        $future->done unless $future->is_ready;
        return;
    }

    # Pump phase (spec section 10.3 pump semantics): drive any ready Future
    # continuations. For the skeleton there are no pending workflow Futures, so
    # the main run Future is either already ready (Future::AsyncAwait ran the
    # body to completion synchronously) or genuinely blocked on a future a
    # later phase resolves. No IO::Async, no wall-clock.
    method _pump {
        # Intentionally minimal: Future::AsyncAwait runs the body and fires its
        # on_ready continuations synchronously when the awaited futures are
        # already resolved, so there is nothing to drive for the skeleton. The
        # loop over pending_futures arrives with P3.4/P3.5.
        return;
    }

    # Build the WorkflowActivationCompletion from the run outcome + command
    # buffer (spec section 10.3 step 6 outcome table; skeleton covers the
    # success path — fail/cancel/task-fail/continue-as-new land in P3.7).
    method _build_completion {
        if (defined $main_run_future && $main_run_future->is_ready) {
            if (my @failure = $main_run_future->failure) {
                # A run-body exception: full outcome decision table is P3.7. For
                # now surface it so the skeleton never silently swallows errors.
                die $failure[0];
            }
            my $result = ($main_run_future->result)[0];
            my $payload = defined $result
                ? $payload_converter->to_payload($result)
                : undef;
            push @commands,
                Temporalio::Workflow::Commands::complete_workflow_execution($payload);
        }

        my $completion_class = Temporalio::Core::Proto::resolve(
            'coresdk.workflow_completion.WorkflowActivationCompletion');
        return $completion_class->new({
            run_id     => $run_id,
            successful => { commands => [@commands] },
        });
    }

    # A self-contained deterministic PRNG seeded from randomness_seed. The
    # contract this phase needs (spec section 10.4 / T-wf-10): same seed ->
    # same sequence, different seed -> different sequence, no OS entropy. This
    # is a SplitMix64-style generator; P3.8 replaces it with the spec-mandated
    # Math::Random::ISAAC::XS primitive (not yet a declared/installed dep).
    # File-scope sub inside the class block so it is callable from methods.
    sub _make_rng ($seed) {
        return Temporalio::Workflow::Runner::_RNG->new($seed);
    }

    # Activity cancellation_type: spec string -> ActivityCancellationType enum
    # number. Defaults to try_cancel (0). The enum lives in
    # coresdk.workflow_commands: TRY_CANCEL=0, WAIT_CANCELLATION_COMPLETED=1,
    # ABANDON=2 (verified against the vendored workflow_commands.proto).
    my %CANCELLATION_TYPE = (
        try_cancel                   => 0,
        wait_cancellation_completed  => 1,
        abandon                      => 2,
    );
    sub _cancellation_type_number ($name) {
        return 0 unless defined $name;
        return $CANCELLATION_TYPE{$name}
            // die "Temporalio::Workflow::Runner: unknown cancellation_type "
                 . "'$name'";
    }

    # Seconds (float) -> google.protobuf.Duration { seconds, nanos }. Mirrors
    # Temporalio::Common::RetryPolicy::_duration; the activity timeouts cross
    # the wire as Durations.
    sub _duration ($seconds) {
        my $Duration = Temporalio::Core::Proto::resolve(
            'google.protobuf.Duration');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Duration->new({ seconds => $whole, nanos => $nanos });
    }
}

# A Workflow::Future for timers whose ->cancel maps to a Temporalio::Exception::
# Cancelled FAILURE (not Future's native cancelled state). Kept in its own
# package because a `feature 'class'` file may declare only one `class :isa`
# once Future::AsyncAwait is loaded (lessons.md), and this is a plain Future
# subclass with one overridden method anyway. The override is the whole point:
# a natively-cancelled CPAN Future makes `await` throw a bare "was cancelled"
# string, losing the Temporal exception identity, whereas the reference SDKs
# raise a cancellation EXCEPTION into the awaiting frame.
package Temporalio::Workflow::Runner::_TimerFuture {
    use v5.38;
    use warnings;

    use parent -norequire, 'Temporalio::Workflow::Future';
    use Temporalio::Exception::Cancelled ();

    # _new_timer(seq => $seq, on_cancel => $cb) -> a pending timer future. The
    # on_cancel callback (emits CancelTimer + de-registers the pending timer)
    # runs exactly once, on the first ->cancel of a still-pending timer.
    sub _new_timer ($class, %args) {
        my $self = $class->new;
        $self->{_timer_on_cancel} = $args{on_cancel};
        return $self;
    }

    # cancel: emit the CancelTimer command (via the stored callback) and fail
    # the future with Temporalio::Exception::Cancelled so the await site sees a
    # proper Temporal cancellation. A no-op once the future is ready (already
    # fired or already cancelled), mirroring the references' pending-state guard.
    sub cancel ($self) {
        return $self if $self->is_ready;
        if (my $cb = delete $self->{_timer_on_cancel}) {
            $cb->();
        }
        $self->fail(Temporalio::Exception::Cancelled->new(
            message => 'Timer cancelled',
        ));
        return $self;
    }
}

# Minimal deterministic RNG (see _make_rng). Kept in its own package — a
# `feature 'class'` file may declare only one `class :isa` once
# Future::AsyncAwait is loaded (lessons.md), and this is a plain blessed
# generator anyway.
package Temporalio::Workflow::Runner::_RNG {
    use v5.38;
    use warnings;

    use constant MASK32 => 0xFFFFFFFF;

    # A 32-bit xorshift generator (Marsaglia). It uses only XOR and bit
    # shifts — no 64-bit multiply — so every step is exact in native Perl
    # integer arithmetic (a 64-bit multiply would overflow to a double and
    # silently lose the low bits). The contract this phase needs is
    # determinism: same seed -> same sequence, different seed -> different
    # sequence, no OS entropy (spec section 10.4 / T-wf-10). P3.8 swaps in the
    # spec-mandated Math::Random::ISAAC::XS primitive.
    sub new ($class, $seed) {
        # Fold the (up to 64-bit) seed into a non-zero 32-bit state. A zero
        # state is a fixed point for xorshift, so force it to 1.
        my $n     = int($seed // 0);
        my $state = (($n & MASK32) ^ (($n >> 32) & MASK32)) & MASK32;
        $state ||= 1;
        return bless { state => $state }, $class;
    }

    # irand: next 32-bit unsigned integer.
    sub irand ($self) {
        my $x = $self->{state};
        $x = ($x ^ ($x << 13)) & MASK32;
        $x = ($x ^ ($x >> 17)) & MASK32;
        $x = ($x ^ ($x << 5))  & MASK32;
        $self->{state} = $x;
        return $x;
    }
}

1;

__END__

=head1 NAME

Temporalio::Workflow::Runner - the deterministic per-run workflow scheduler

=head1 SYNOPSIS

    use Temporalio::Workflow::Runner;

    my $runner = Temporalio::Workflow::Runner->new(
        workflow_class => 'My::Workflow::Greeting',
    );

    my $completion = $runner->process_activation($activation);
    # $completion is a coresdk WorkflowActivationCompletion proto

=head1 DESCRIPTION

One instance per workflow run (the dispatcher caches them by run id; the cache
lands in P3.6). The runner applies an activation's jobs, drives the workflow
C<:Run> body via manually-resolved L<Temporalio::Workflow::Future> objects
(B<never> via IO::Async timers or the wall clock — spec section 10.3), buffers
the commands the body emits, and drains them into a
C<WorkflowActivationCompletion> proto.

The workflow body runs under a dynamically-scoped C<$CURRENT> pointer (set with
L<Syntax::Keyword::Dynamically>, not C<local>, because the scope must survive
an C<await> — spec section 16.1) so that the C<Temporalio::Workflow::> context
functions (C<now>, C<time>, C<is_replaying>, C<info>, C<random>, ...) resolve
to the active runner.

=head2 Determinism

C<now>/C<time> derive from the activation timestamp, never the OS clock.
C<random> returns a generator seeded from the C<InitializeWorkflow> job's
C<randomness_seed> (not the run id), so two runs with the same seed produce the
same sequence (spec test T-wf-10). The skeleton ships a self-contained
SplitMix64-style generator; P3.8 replaces it with the spec-mandated
C<Math::Random::ISAAC::XS> primitive.

=head2 Scope

Handles C<InitializeWorkflow>, activity scheduling
(C<execute_activity>/C<start_activity> -> C<ScheduleActivity> command +
C<ResolveActivity> job, P3.4), timers (C<start_timer>/C<sleep> -> C<StartTimer>
command + C<FireTimer> job, with C<CancelTimer> on Future cancel, P3.5), and the
success completion outcome. Each activity is tracked by its command C<seq> in a
pending-Futures map and resolved imperatively when the matching
C<ResolveActivity> job arrives (completed -> C<< ->done >>, failed/cancelled ->
C<< ->fail >> with the exception mapped from the Failure proto). Each timer is
tracked likewise and resolved on its C<FireTimer> job (C<< ->done >>) or, when
the timer Future is cancelled, removed and failed with a
L<Temporalio::Exception::Cancelled> after emitting C<CancelTimer>. The
dispatcher cache and eviction (P3.6) and the full
fail/cancel/task-fail/continue-as-new outcome table (P3.7) land in later phases.

=head2 Sequence numbers

Command sequence numbers (spec section 10.3) are workflow-scoped, monotonic
from 1, allocated at command-emission time and persisted across activations.
Each command type allocates from its OWN seq space: activities and timers each
start at 1 independently (MUST-match sdk-python C<_next_seq("activity")> vs
C<_next_seq("timer")>; sdk-ruby C<@activity_counter> vs C<@timer_counter>), so a
workflow's first activity and first timer are both seq 1. The command buffer, by
contrast, holds only the current activation's commands (the worker returns one
completion per activation).

=cut
