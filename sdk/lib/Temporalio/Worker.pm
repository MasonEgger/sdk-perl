# ABOUTME: Temporal worker (spec section 8): construction, WorkerOptions
# ABOUTME: marshalling, validate, and the initiate/finalize/free shutdown sequence.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;

use FFI::Platypus::Buffer ();
use Scalar::Util ();
use Temporalio::Core::ByteArray ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Core::FFI::WorkerOptions ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Bridge ();
use Temporalio::Exception::Runtime ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::ActivityRegistry ();
use Temporalio::Worker::PollLoop ();

class Temporalio::Worker {
    # --- spec section 8.1 kwargs -----------------------------------------
    # client/task_queue default to undef so a missing one surfaces from ADJUST
    # as an Exception::Argument (not the native "Required parameter" die).
    field $client     :param = undef;
    field $task_queue :param = undef;
    field $workflows  :param = [];
    field $activities :param = [];

    # WorkerOptions kwargs (spec 8.1). Defaults verified against sdk-ruby
    # worker.rb (lines 447-465) + the FixedSize tuner default of 100
    # (tuner.rb 266-269). Time fields are seconds Perl-side, packed as millis.
    field $build_id                            :param = undef;
    field $identity_override                   :param = undef;
    field $max_cached_workflows                :param = 1000;
    field $max_concurrent_workflow_tasks       :param = 100;
    field $max_concurrent_activities           :param = 100;
    field $max_concurrent_local_activities     :param = 100;
    field $max_concurrent_workflow_task_polls  :param = 5;
    field $max_concurrent_activity_task_polls  :param = 5;
    field $nonsticky_to_sticky_poll_ratio      :param = 0.2;
    field $sticky_queue_schedule_to_start_timeout :param = 10;
    field $max_heartbeat_throttle_interval     :param = 60;
    field $default_heartbeat_throttle_interval :param = 30;
    field $max_activities_per_second           :param = undef;
    field $max_task_queue_activities_per_second :param = undef;
    field $graceful_shutdown_period            :param = 0;
    field $workflow_failure_exception_types    :param = [];
    field $nondeterminism_as_workflow_fail     :param = 0;

    field $activity_registry;
    field $worker_ptr;       # TemporalCoreWorker*, NULL until _ensure_worker
    field $worker_keep;      # @keep pinning the packed options buffer
    field $is_shutdown = 0;
    field $is_running  = 0;  # true between run start and its return
    field $initiated   = 0;  # initiate_shutdown sent once

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => 'Temporalio::Worker->new requires a client')
            unless defined $client;
        Temporalio::Exception::Argument->throw(
            message => 'Temporalio::Worker->new requires a non-empty task_queue')
            unless defined $task_queue && length $task_queue;

        $activity_registry = Temporalio::Worker::ActivityRegistry->new(
            activities => $activities);
        # Workflow registration (spec 8.6) needs Temporalio::Workflow::Definition,
        # which lands in P3.1; v0.1 construction accepts and stores the list.
    }

    method client             { $client }
    method task_queue         { $task_queue }
    method workflows          { $workflows }
    method activity_registry  { $activity_registry }
    method is_shutdown        { $is_shutdown }

    # _build_worker_options(\@keep) -> opaque pointer to the packed
    # TemporalCoreWorkerOptions buffer (spec 8.1). The pointer is valid while
    # @$keep lives. Namespace + identity flow from the client; an
    # identity_override of undef means "use the client identity" (the bridge
    # falls back to the client's identity when the override is NULL, matching
    # sdk-ruby worker.rb identity_override: @options.identity).
    method _build_worker_options ($keep) {
        return Temporalio::Core::FFI::WorkerOptions::build($keep,
            namespace            => $client->namespace,
            task_queue           => $task_queue,
            # versioning None{build_id}; an undef build_id packs as an empty
            # ByteArrayRef (spec 8.1 — deployment/legacy versioning is Phase 6+).
            versioning_build_id  => $build_id,
            identity_override    => $identity_override,
            max_cached_workflows => $max_cached_workflows,

            # FixedSize tuner from the max_concurrent_* slots; the nexus slot
            # supplier is a fixed 100 in v0.1 (spec 8.1).
            workflow_slots       => $max_concurrent_workflow_tasks,
            activity_slots       => $max_concurrent_activities,
            local_activity_slots => $max_concurrent_local_activities,
            nexus_task_slots     => 100,

            # task_types: workflows + remote activities only (spec 8.1).
            enable_workflows         => 1,
            enable_local_activities  => 0,
            enable_remote_activities => 1,
            enable_nexus             => 0,

            sticky_queue_schedule_to_start_timeout_millis =>
                int($sticky_queue_schedule_to_start_timeout * 1000),
            max_heartbeat_throttle_interval_millis =>
                int($max_heartbeat_throttle_interval * 1000),
            default_heartbeat_throttle_interval_millis =>
                int($default_heartbeat_throttle_interval * 1000),
            # 0.0 means "unset" to the bridge (no rate limit).
            max_activities_per_second            => $max_activities_per_second // 0,
            max_task_queue_activities_per_second =>
                $max_task_queue_activities_per_second // 0,
            graceful_shutdown_period_millis => int($graceful_shutdown_period * 1000),

            workflow_task_poller_simple_maximum => $max_concurrent_workflow_task_polls,
            activity_task_poller_simple_maximum => $max_concurrent_activity_task_polls,
            nexus_task_poller_simple_maximum    => 5,
            nonsticky_to_sticky_poll_ratio      => $nonsticky_to_sticky_poll_ratio,

            nondeterminism_as_workflow_fail => $nondeterminism_as_workflow_fail ? 1 : 0,
            nondeterminism_as_workflow_fail_for_types =>
                $workflow_failure_exception_types,
            plugins         => [],
            storage_drivers => [],
        );
    }

    method _runtime () { $client->runtime }

    # Lazily build the core worker (spec 8.2 step 1): pack the options and
    # call temporal_core_worker_new, raising on failure. The packed options
    # buffer must outlive the worker (the bridge copies what it needs during
    # the call, but @keep is held as a field for safety).
    method _ensure_worker () {
        $self->_assert_open;
        return $worker_ptr if defined $worker_ptr;

        $worker_keep = [];
        my $options_ptr = $self->_build_worker_options($worker_keep);
        my $result = Temporalio::Core::FFI::worker_new(
            $client->connection->ptr, $options_ptr);

        my $fail_ptr = scalar $result->fail;
        if (defined $fail_ptr) {
            my $runtime = $self->_runtime;
            my $byte_array = Temporalio::Core::ByteArray->wrap($fail_ptr, $runtime);
            my $message    = $byte_array->bytes;
            $byte_array->free;
            $worker_keep = undef;
            Temporalio::Exception::Bridge->throw(
                message => "worker creation failed: $message");
        }
        $worker_ptr = scalar $result->worker;
        return $worker_ptr;
    }

    method _assert_open () {
        Temporalio::Exception::Runtime->throw(message => 'Worker is shut down')
            if $is_shutdown;
        return;
    }

    # validate (spec 8.2 step 2): builds the core worker if needed, then calls
    # temporal_core_worker_validate over the callback bridge ('worker' kind,
    # fail-or-nothing). A non-null fail raises before any polling would start.
    async method validate () {
        my $ptr     = $self->_ensure_worker;
        my $runtime = $self->_runtime;
        await Temporalio::Core::Callback->issue_async(
            $runtime, worker => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::worker_validate(
                    $ptr, $user_data, $trampoline);
            });
        return;
    }

    # run (spec 8.2 steps 1-5): build + validate the worker if needed, then
    # drive the activity poll loop (the workflow loop lands in P3.6). Returns
    # when the loop drains — either because `shutdown` was called mid-run
    # (initiate_shutdown makes core return the ShutDown sentinel from poll) or
    # because core shut the worker down for another reason. On the way out it
    # finalizes and frees the worker (the full graceful sequence deferred from
    # `shutdown` per the P2.2 deadlock note). T-wkr-4: shutdown mid-run causes
    # run to return; a second shutdown is a no-op.
    async method run () {
        $self->_assert_open;
        await $self->validate;     # _ensure_worker + pre-poll validate
        $is_running = 1;

        my $runtime    = $self->_runtime;
        my $dispatcher = $self->_build_activity_dispatcher;
        my $poll_loop  = Temporalio::Worker::PollLoop->new(
            dispatcher  => $dispatcher,
            poll_source => sub { return $self->_poll_activity_task },
            loop        => $runtime->loop,
        );

        my $error;
        {
            local $@;
            eval { await $poll_loop->run; 1 } or $error = $@;
        }

        # The loop has drained (sentinel seen). Make sure shutdown was actually
        # initiated (the loop may have exited because core shut down on its
        # own), then finalize + free. _finalize_and_free is idempotent.
        $self->_initiate_shutdown_once;
        await $self->_finalize_and_free;
        $is_running  = 0;
        $is_shutdown = 1;

        die $error if defined $error;
        return;
    }

    # Build the activity dispatcher with the real completer (worker_complete_
    # activity_task over the callback bridge) and the synchronous heartbeat
    # recorder (worker_record_activity_heartbeat). The completer holds the
    # serialized completion ByteArrayRef buffer through the callback (the
    # bridge borrows it — header), so @keep lives until the Future resolves.
    method _build_activity_dispatcher () {
        my $runtime = $self->_runtime;
        return Temporalio::Worker::ActivityDispatcher->new(
            registry       => $activity_registry,
            data_converter => $client->data_converter,
            task_queue     => $task_queue,
            client         => $client,
            loop           => $runtime->loop,
            completer      => sub ($completion_bytes) {
                return $self->_complete_activity_task($completion_bytes);
            },
            heartbeat_recorder => sub ($heartbeat_bytes) {
                return $self->_record_heartbeat($heartbeat_bytes);
            },
        );
    }

    # Issue worker_poll_activity_task over the callback bridge ('worker_poll'
    # kind): resolves with the serialized ActivityTask bytes, or undef on the
    # ShutDown sentinel.
    method _poll_activity_task () {
        my $runtime = $self->_runtime;
        return Temporalio::Core::Callback->issue_async(
            $runtime, worker_poll => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::worker_poll_activity_task(
                    $worker_ptr, $user_data, $trampoline);
            });
    }

    # Issue worker_complete_activity_task over the callback bridge ('worker'
    # kind, fail-or-nothing). The completion bytes are passed as a
    # ByteArrayRef; @keep pins the buffer through the call.
    method _complete_activity_task ($completion_bytes) {
        my $runtime = $self->_runtime;
        my @keep;
        my ($data, $size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $completion_bytes);
        my $ref = Temporalio::Core::FFI::ByteArrayRef->new(
            data => $data, size => $size);
        my $f = Temporalio::Core::Callback->issue_async(
            $runtime, worker => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::worker_complete_activity_task(
                    $worker_ptr, $ref, $user_data, $trampoline);
            });
        # Hold @keep (and $ref) until the completion callback fires.
        return $f->on_ready(sub { @keep = (); undef $ref });
    }

    # Synchronous heartbeat: worker_record_activity_heartbeat returns NULL on
    # success or an owned byte array describing the error. Returns the error
    # string (or undef) for Activity::Context->heartbeat to raise on.
    method _record_heartbeat ($heartbeat_bytes) {
        my $runtime = $self->_runtime;
        my @keep;
        my ($data, $size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $heartbeat_bytes);
        my $ref = Temporalio::Core::FFI::ByteArrayRef->new(
            data => $data, size => $size);
        my $fail_ptr = Temporalio::Core::FFI::worker_record_activity_heartbeat(
            $worker_ptr, $ref);
        return undef unless defined $fail_ptr;
        my $byte_array = Temporalio::Core::ByteArray->wrap($fail_ptr, $runtime);
        my $message    = $byte_array->bytes;
        $byte_array->free;
        return $message;
    }

    method _initiate_shutdown_once () {
        return if $initiated || !defined $worker_ptr;
        Temporalio::Core::FFI::worker_initiate_shutdown($worker_ptr);
        $initiated = 1;
        return;
    }

    # Finalize (async, awaits core's Worker::shutdown — safe only once the poll
    # loops have drained, P2.2 lesson) then free. Idempotent: a NULL worker_ptr
    # means already freed.
    async method _finalize_and_free () {
        return unless defined $worker_ptr;
        my $runtime = $self->_runtime;
        my $ptr     = $worker_ptr;
        await Temporalio::Core::Callback->issue_async(
            $runtime, worker => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::worker_finalize_shutdown(
                    $ptr, $user_data, $trampoline);
            });
        Temporalio::Core::FFI::worker_free($ptr);
        $worker_ptr  = undef;
        $worker_keep = undef;
        return;
    }

    # shutdown (spec 8.2 step 5): idempotent. Returns a Future so callers can
    # `await $worker->shutdown` uniformly.
    #
    # While `run` is driving the poll loops, shutdown only INITIATES: that makes
    # core return the ShutDown sentinel from the next poll, the loop drains, and
    # `run` itself does the finalize + free (the async finalize awaits core's
    # Worker::shutdown, which blocks until the loops return ShutDown — calling
    # it here would deadlock, P2.2 lesson). For a worker that was never run
    # (construction + validate only, P2.2), there is no loop to drain, so
    # shutdown does the synchronous initiate + free directly (no finalize, which
    # would deadlock with no loop driving the polls).
    method shutdown () {
        my $runtime = eval { $self->_runtime };
        if ($is_running) {
            # Mid-run: just initiate; `run` finalizes + frees on its way out.
            $self->_initiate_shutdown_once;
            return $runtime ? $runtime->loop->new_future->done : Future->done;
        }
        if (!$is_shutdown && defined $worker_ptr) {
            Temporalio::Core::FFI::worker_initiate_shutdown($worker_ptr);
            Temporalio::Core::FFI::worker_free($worker_ptr);
            $worker_ptr  = undef;
            $worker_keep = undef;
            $initiated   = 1;
        }
        $is_shutdown = 1;
        return $runtime ? $runtime->loop->new_future->done : Future->done;
    }
}

# Wrap the generated constructor so an unrecognised kwarg surfaces as
# Exception::Argument (spec 8.1 — typos are caught, not passed to core). The
# native `class` `new` dies with a plain string before ADJUST can run, so the
# only clean intercept is around the constructor itself. Missing client /
# task_queue are handled in ADJUST (they default to undef).
{
    my $orig_new = Temporalio::Worker->can('new');
    no warnings 'redefine';
    *Temporalio::Worker::new = sub ($class, %args) {
        my $self = eval { $orig_new->($class, %args) };
        if (!defined $self) {
            my $err = $@;
            if (Scalar::Util::blessed($err)) { die $err }    # ADJUST's Argument
            if ($err =~ /Unrecognised parameters? for/) {
                Temporalio::Exception::Argument->throw(
                    message => "Temporalio::Worker->new: $err");
            }
            die $err;
        }
        return $self;
    };
}

1;

__END__

=head1 NAME

Temporalio::Worker - poll a task queue and dispatch workflows and activities

=head1 SYNOPSIS

    use Temporalio::Worker;

    my $worker = Temporalio::Worker->new(
        client     => $client,
        task_queue => 'demo',
        activities => [ 'My::Activity::SayHello', $function_definition ],
        workflows  => [ 'My::Workflow::Greeting' ],
        max_concurrent_activities => 100,
        build_id                  => 'my-build-2026',
    );

    await $worker->validate;     # reaches the server; raises on failure
    # await $worker->run;        # poll loops land in P2.4/P3.6
    await $worker->shutdown;     # initiate -> finalize -> free; idempotent

=head1 DESCRIPTION

The Temporal worker (spec section 8). Construction (spec 8.1) builds the
activity registry from the C<activities> list
(L<Temporalio::Worker::ActivityRegistry>) and records the configuration; the
C<workflows> list is accepted and stored (workflow registration lands with
L<Temporalio::Workflow::Definition> in a later phase). A missing client or an
empty task queue raises L<Temporalio::Exception::Argument>.

The WorkerOptions are marshalled by L<Temporalio::Core::FFI::WorkerOptions>
(the hand-packed C<TemporalCoreWorkerOptions> buffer proven in plan P0.10):
versioning is always C<None{build_id}>, the tuner is four C<FixedSize> slot
suppliers built from the C<max_concurrent_*> kwargs, task types enable
workflows + remote activities only, and the pollers are C<simple_maximum>.
Time-valued kwargs are seconds Perl-side and packed as milliseconds.
Defaults match the reference SDKs (sdk-ruby C<worker.rb>): cache 1000, slots
100, sticky 10s, heartbeat throttle 60s/30s, graceful shutdown 0s, pollers 5,
nonsticky-to-sticky ratio 0.2.

C<validate> (spec 8.2 step 2) lazily creates the core worker via
C<temporal_core_worker_new> (raising L<Temporalio::Exception::Bridge> on
failure) and then awaits C<temporal_core_worker_validate> over the callback
bridge; a non-null failure raises before any polling would start.
C<shutdown> (spec 8.2 step 5) is idempotent and returns a ready Future so
callers can C<await $worker-E<gt>shutdown> uniformly. For a worker that was
never run (construction + validate only), it calls
C<temporal_core_worker_initiate_shutdown> then C<temporal_core_worker_free>.
It deliberately does NOT call the async C<temporal_core_worker_finalize_shutdown>
here: finalize awaits core's worker shutdown, which blocks until the
workflow/activity poll loops return C<ShutDown> — and with no C<run> loop
driving them that await would deadlock. The full graceful sequence
(initiate, drain in-flight activities up to C<graceful_shutdown_period>,
finalize, free) is issued from C<run> once the poll loops have drained;
C<run> and those loops arrive in later plan steps (P2.4 / P3.6).

=cut
