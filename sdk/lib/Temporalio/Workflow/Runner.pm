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
use Temporalio::Converter::Payload ();
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

    field $instance;                 # the workflow Definition instance
    field $workflow_type;            # resolved run type name
    field @commands;                 # outbound WorkflowCommand buffer
    field $main_run_future;          # the Future returned by :Run

    # Activation context (set per activation; never the OS clock).
    field $activation_seconds = 0;
    field $activation_nanos   = 0;
    field $is_replaying       = 0;

    # Deterministic RNG state (seeded from the InitializeWorkflow job's
    # randomness_seed). See _make_rng below.
    field $rng;

    ADJUST {
        $payload_converter //= Temporalio::Converter::Payload->default;
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
        # FireTimer / ResolveActivity / SignalWorkflow / QueryWorkflow /
        # CancelWorkflow / RemoveFromCache and friends land in later phases.
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

=head2 Scope (P3.3 skeleton)

This skeleton handles C<InitializeWorkflow> and the success completion outcome.
Activity scheduling and C<ResolveActivity> (P3.4), timers (P3.5), the
dispatcher cache and eviction (P3.6), and the full fail/cancel/task-fail/
continue-as-new outcome table (P3.7) land in later phases.

=cut
