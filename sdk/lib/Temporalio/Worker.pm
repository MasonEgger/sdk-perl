# ABOUTME: Temporal worker (spec section 8): construction, WorkerOptions
# ABOUTME: marshalling, validate, and the initiate/finalize/free shutdown sequence.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;

use Digest::MD5 ();
use FFI::Platypus::Buffer ();
use Scalar::Util ();
use Temporalio::Core::ByteArray ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Core::FFI::WorkerOptions ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Bridge ();
use Temporalio::Exception::Runtime ();
use Temporalio::Activity::Pool ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::ActivityRegistry ();
use Temporalio::Worker::Interceptor ();
use Temporalio::Worker::NexusDispatcher ();
use Temporalio::Worker::NexusRegistry ();
use Temporalio::Worker::PollLoop ();
use Temporalio::Worker::WorkflowDispatcher ();
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Workflow::DeterminismGuard ();

class Temporalio::Worker {
    # --- spec section 8.1 kwargs -----------------------------------------
    # client/task_queue default to undef so a missing one surfaces from ADJUST
    # as an Exception::Argument (not the native "Required parameter" die).
    field $client     :param = undef;
    field $task_queue :param = undef;
    field $workflows  :param = [];
    field $activities :param = [];
    field $nexus_services :param = [];
    # Interceptors (spec section 27): the worker inherits the client's list and
    # appends its own; the combined list folds first-listed outermost for the
    # inbound activity/workflow chains.
    field $interceptors :param = [];
    field $all_interceptors;

    # WorkerOptions kwargs (spec 8.1). Defaults verified against sdk-ruby
    # worker.rb (lines 447-465) + the FixedSize tuner default of 100
    # (tuner.rb 266-269). Time fields are seconds Perl-side, packed as millis.
    field $build_id                            :param = undef;
    # Worker versioning (spec §29.1). deployment_options selects the
    # deployment-based strategy (primary); build_id + use_worker_versioning
    # select the deprecated legacy build-id strategy. The two are mutually
    # exclusive (validated in ADJUST). When neither versioning path is on, the
    # None{build_id} default carries build_id as a plain per-process identity.
    field $deployment_options                  :param = undef;
    field $use_worker_versioning               :param = 0;
    field $identity_override                   :param = undef;
    field $max_cached_workflows                :param = 1000;
    field $max_concurrent_workflow_tasks       :param = 100;
    field $max_concurrent_activities           :param = 100;
    field $max_concurrent_local_activities     :param = 100;
    # Legacy poll-count kwargs (spec §29.3, DEPRECATED). undef means "unset" so
    # an explicitly-passed value can override a poller-behavior object with
    # SimpleMaximum(that) per the Python override model (_worker.py:587-598).
    field $max_concurrent_workflow_task_polls  :param = undef;
    field $max_concurrent_activity_task_polls  :param = undef;
    # Poller behaviors (spec §29.3). Each accepts a
    # Temporalio::Worker::PollerBehavior::{SimpleMaximum,Autoscaling}. The
    # default is SimpleMaximum(5) (built in ADJUST to avoid loading the class at
    # field-init time). The behavior field is primary; an explicitly-set legacy
    # max_concurrent_*_task_polls overrides it with SimpleMaximum(that). Nexus
    # has no legacy equivalent and is taken directly.
    field $workflow_task_poller_behavior       :param = undef;
    field $activity_task_poller_behavior       :param = undef;
    field $nexus_task_poller_behavior          :param = undef;
    # Worker tuner (spec §29.2). A Temporalio::Worker::Tuner holding four slot
    # suppliers, mutually exclusive with the max_concurrent_* slot kwargs. When
    # absent the worker synthesizes a FixedSize tuner from those kwargs (v0.1
    # parity). $tuner_custom_registered tracks whether this worker claimed the
    # runtime's process-global custom-supplier registry (released at shutdown).
    field $tuner                               :param = undef;
    field $tuner_custom_registered = 0;
    field $nonsticky_to_sticky_poll_ratio      :param = 0.2;
    field $sticky_queue_schedule_to_start_timeout :param = 10;
    field $max_heartbeat_throttle_interval     :param = 60;
    field $default_heartbeat_throttle_interval :param = 30;
    field $max_activities_per_second           :param = undef;
    field $max_task_queue_activities_per_second :param = undef;
    field $graceful_shutdown_period            :param = 0;
    field $workflow_failure_exception_types    :param = [];
    field $nondeterminism_as_workflow_fail     :param = 0;

    # Eager activity dispatch (spec section 23.2). Two distinct knobs:
    #   no_remote_activities (default 0): a BRIDGE WorkerOptions field — the
    #     bridge enable_remote_activities is !no_remote_activities. When true,
    #     an eager activity declined for lack of remote slots cannot fall back to
    #     remote scheduling and the activity times out schedule-to-start.
    #   disable_eager_activity_execution (default 0): a WORKFLOW-side flag that
    #     suppresses the eager-execution request on the schedule_activity command
    #     (do_not_eagerly_execute). It threads worker -> WorkflowDispatcher ->
    #     Runner -> ScheduleActivity, NOT the bridge WorkerOptions.
    field $no_remote_activities                :param = 0;
    field $disable_eager_activity_execution    :param = 0;

    # Determinism guard (spec §29.4). Default ON: the worker installs the
    # best-effort time/entropy guard (Temporalio::Workflow::DeterminismGuard) so
    # a workflow body that calls a trapped builtin throws Nondeterminism. Set
    # true to skip installation (the guard is process-global and cannot be
    # cleanly uninstalled, so "disable" means this worker never installs it).
    field $disable_determinism_guard           :param = 0;

    # IO::Async::Function fork-pool size for sync activities (spec section 8.1
    # / 9.4). Only the count matters Perl-side; sync activities run in a child.
    field $sync_activity_workers               :param = 4;

    field $activity_registry;
    field $workflow_registry;
    field $nexus_registry;
    field $activity_pool;    # Temporalio::Activity::Pool, built lazily in run
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

        # Determinism guard (spec §29.4): default ON. Installing it is safe even
        # if there is no workflow on this worker — the overrides delegate to the
        # real builtin unless a workflow body is on the stack. Idempotent, so
        # multiple workers (or a re-run) share one install.
        Temporalio::Workflow::DeterminismGuard::install()
            unless $disable_determinism_guard;

        # Worker versioning (spec §29.1): exactly one strategy reaches core.
        # deployment_options (deployment-based) is mutually exclusive with the
        # legacy build_id/use_worker_versioning pair.
        if (defined $deployment_options) {
            Temporalio::Exception::Argument->throw(
                message => 'deployment_options must be a '
                    . 'Temporalio::Worker::DeploymentOptions')
                unless ref $deployment_options
                    && $deployment_options->isa(
                        'Temporalio::Worker::DeploymentOptions');
            Temporalio::Exception::Argument->throw(
                message => 'deployment_options is mutually exclusive with '
                    . 'use_worker_versioning')
                if $use_worker_versioning;
            Temporalio::Exception::Argument->throw(
                message => 'deployment_options is mutually exclusive with '
                    . 'build_id')
                if defined $build_id;
        }

        # build_id default (spec §29.1 resolved WH-5): MD5 of the sorted %INC
        # contents — a stable per-process worker identity. Computed only when
        # the caller did not supply a build_id (and deployment versioning, which
        # carries its own build_id, is not in use).
        if (!defined $build_id && !defined $deployment_options) {
            $build_id = _default_build_id();
        }

        # Worker tuner (spec §29.2): must be a Temporalio::Worker::Tuner when
        # given. The mutual exclusion with max_concurrent_* is enforced in the
        # constructor wrapper (it needs the raw args).
        if (defined $tuner) {
            Temporalio::Exception::Argument->throw(
                message => 'tuner must be a Temporalio::Worker::Tuner')
                unless ref $tuner
                    && $tuner->isa('Temporalio::Worker::Tuner');
        }

        # Poller behaviors (spec §29.3): each kwarg, when given, must be a
        # PollerBehavior::{SimpleMaximum,Autoscaling}. undef means the
        # SimpleMaximum(5) default.
        for my $pair (
            [workflow_task_poller_behavior => $workflow_task_poller_behavior],
            [activity_task_poller_behavior => $activity_task_poller_behavior],
            [nexus_task_poller_behavior    => $nexus_task_poller_behavior],
        ) {
            my ($name, $behavior) = @$pair;
            next unless defined $behavior;
            Temporalio::Exception::Argument->throw(
                message => "$name must be a "
                    . 'Temporalio::Worker::PollerBehavior::SimpleMaximum or '
                    . '::Autoscaling')
                unless ref $behavior
                    && ($behavior->isa(
                            'Temporalio::Worker::PollerBehavior::SimpleMaximum')
                        || $behavior->isa(
                            'Temporalio::Worker::PollerBehavior::Autoscaling'));
        }

        $activity_registry = Temporalio::Worker::ActivityRegistry->new(
            activities => $activities);
        # Workflow registration (spec 8.6): resolve each class name to its
        # workflow type, requiring one :Run and rejecting duplicates.
        $workflow_registry = Temporalio::Worker::WorkflowRegistry->new(
            workflows => $workflows);
        # Nexus service registration (spec section 26.2): resolve each class name
        # or instance to its service + operations, rejecting duplicate service
        # names.
        $nexus_registry = Temporalio::Worker::NexusRegistry->new(
            nexus_services => $nexus_services);

        # The worker inherits the client's interceptor list and appends its own
        # (spec section 27.2). The combined list drives both inbound chains; the
        # client list already drives the client outbound chain. (A test double
        # client may not implement ->interceptors; treat that as an empty list.)
        my $client_list =
            $client->can('interceptors') ? $client->interceptors : [];
        $all_interceptors = [ @{ $client_list // [] }, @$interceptors ];
    }

    # MD5 hex of the sorted, NUL-joined "<module>\0<path>" pairs from %INC — a
    # stable per-process build identity (spec §29.1 WH-5; bytes need not match
    # other SDKs). File-scope sub so ADJUST can call it.
    sub _default_build_id () {
        my $md5 = Digest::MD5->new;
        for my $module (sort keys %INC) {
            $md5->add($module, "\0", ($INC{$module} // ''), "\0");
        }
        return $md5->hexdigest;
    }

    method build_id           { $build_id }
    method client             { $client }
    method task_queue         { $task_queue }
    method workflows          { $workflows }
    method activity_registry  { $activity_registry }
    method workflow_registry  { $workflow_registry }
    method nexus_registry     { $nexus_registry }
    method is_shutdown        { $is_shutdown }
    method interceptors       { $all_interceptors }

    # build_activity_inbound($root) / build_workflow_inbound($root) — fold the
    # combined interceptor list (client + worker) over the supplied root impl,
    # first-listed outermost (spec section 27.2). The dispatchers call these to
    # wrap the real activity/workflow dispatch.
    method build_activity_inbound ($root) {
        return Temporalio::Worker::Interceptor::build_activity_inbound(
            $all_interceptors, $root);
    }
    method build_workflow_inbound ($root) {
        return Temporalio::Worker::Interceptor::build_workflow_inbound(
            $all_interceptors, $root);
    }

    # _build_worker_options(\@keep) -> opaque pointer to the packed
    # TemporalCoreWorkerOptions buffer (spec 8.1). The pointer is valid while
    # @$keep lives. Namespace + identity flow from the client; an
    # identity_override of undef means "use the client identity" (the bridge
    # falls back to the client's identity when the override is NULL, matching
    # sdk-ruby worker.rb identity_override: @options.identity).
    # _versioning_strategy() -> the versioning keys for WorkerOptions::build
    # (spec §29.1). Exactly one strategy is selected (resolution
    # deployment → legacy → none-carrying-build_id):
    #   deployment_options  -> versioning_deployment (DeploymentBased, tag 1)
    #   use_worker_versioning -> versioning_legacy_build_id (Legacy, tag 2)
    #   otherwise           -> versioning_build_id (None{build_id}, tag 0)
    method _versioning_strategy () {
        if (defined $deployment_options) {
            my $version = $deployment_options->version;
            return (
                versioning_deployment => {
                    deployment_name => $version->deployment_name,
                    build_id        => $version->build_id,
                    use_worker_versioning =>
                        $deployment_options->use_worker_versioning,
                    default_versioning_behavior =>
                        $deployment_options->default_versioning_behavior_value,
                },
            );
        }
        if ($use_worker_versioning) {
            return (versioning_legacy_build_id => $build_id);
        }
        return (versioning_build_id => $build_id);
    }

    # _slot_supplier_options() -> the four *_slot_supplier_spec kwargs for
    # WorkerOptions::build (spec §29.2). With an explicit tuner each pool packs
    # its supplier's _pack_spec; custom suppliers are registered with the
    # runtime's process-global registry first so their callbacks pointer is
    # bound before packing. With no tuner, fall back to the legacy *_slots
    # FixedSize defaults (v0.1 parity) — WorkerOptions::build synthesizes them.
    method _slot_supplier_options () {
        unless (defined $tuner) {
            return (
                workflow_slots       => $max_concurrent_workflow_tasks,
                activity_slots       => $max_concurrent_activities,
                local_activity_slots => $max_concurrent_local_activities,
                nexus_task_slots     => 100,
            );
        }

        $self->_register_custom_suppliers;
        return (
            workflow_slot_supplier_spec =>
                $tuner->workflow_slot_supplier->_pack_spec,
            activity_slot_supplier_spec =>
                $tuner->activity_slot_supplier->_pack_spec,
            local_activity_slot_supplier_spec =>
                $tuner->local_activity_slot_supplier->_pack_spec,
            nexus_task_slot_supplier_spec =>
                $tuner->nexus_task_slot_supplier->_pack_spec,
        );
    }

    # Register every Custom slot supplier in the tuner with the runtime's
    # process-global custom-supplier registry (spec §29.2). Each gets a
    # shim-allocated callbacks struct whose pointer is bound onto the supplier
    # so its _pack_spec packs that pointer into the Custom union. Idempotent per
    # worker. Skipped entirely when the tuner has no Custom suppliers.
    method _register_custom_suppliers () {
        my @custom = grep {
            $_->isa('Temporalio::Worker::SlotSupplier::Custom')
        } $tuner->suppliers;
        return unless @custom;

        require Temporalio::Worker::SlotSupplierRegistry;
        my $runtime = $self->_runtime;

        # Claim the process-global registry for this runtime's queue (refuse a
        # second active custom-supplier set, mirroring the meter rule).
        unless ($tuner_custom_registered) {
            Temporalio::Core::FFI::bind_supplier_complete_reserve();
            unless (Temporalio::Core::FFI::supplier_register($runtime->queue_ptr)) {
                Temporalio::Exception::Argument->throw(
                    message => 'a custom slot supplier is already active on'
                        . ' another runtime in this process (only one allowed)');
            }
            Temporalio::Worker::SlotSupplierRegistry->_set_active;
            $tuner_custom_registered = 1;
        }

        for my $supplier (@custom) {
            # Already bound (e.g. a re-validate) -> keep the existing pointer.
            next if $supplier->_callbacks_ptr;
            my $cb_ptr = Temporalio::Core::FFI::supplier_new()
                or Temporalio::Exception::Runtime->throw(
                    message => 'failed to allocate a custom slot supplier'
                        . ' (no active registry)');
            $supplier->_set_callbacks_ptr($cb_ptr);
            # The shim sets the callbacks struct user_data to a supplier id; read
            # it back so the registry can dispatch drained requests to this impl.
            my $id = Temporalio::Core::FFI::supplier_callbacks_user_data($cb_ptr);
            Temporalio::Worker::SlotSupplierRegistry->_register_impl(
                $id, $supplier->impl);
        }
        return;
    }

    # _poller_behavior_options() -> the three *_poller_behavior_spec kwargs for
    # WorkerOptions::build (spec §29.3). The behavior object is primary; an
    # explicitly-set legacy max_concurrent_*_task_polls overrides the workflow /
    # activity behavior with SimpleMaximum(that) (Python _worker.py:587-598).
    # Nexus has no legacy equivalent. The default behavior is SimpleMaximum(5).
    # The resolved workflow behavior must allow >= 2 concurrent polls (core
    # constraint); a smaller SimpleMaximum is an Argument.
    method _poller_behavior_options () {
        require Temporalio::Worker::PollerBehavior::SimpleMaximum;

        my $resolve = sub ($behavior, $override) {
            # An explicit legacy poll count overrides the behavior entirely.
            if (defined $override) {
                return Temporalio::Worker::PollerBehavior::SimpleMaximum->new(
                    maximum => $override);
            }
            return $behavior
                // Temporalio::Worker::PollerBehavior::SimpleMaximum->new;
        };

        my $workflow = $resolve->(
            $workflow_task_poller_behavior, $max_concurrent_workflow_task_polls);
        my $activity = $resolve->(
            $activity_task_poller_behavior, $max_concurrent_activity_task_polls);
        my $nexus = $nexus_task_poller_behavior
            // Temporalio::Worker::PollerBehavior::SimpleMaximum->new;

        # Core requires the workflow-task pool to allow >= 2 concurrent polls.
        if ($workflow->isa('Temporalio::Worker::PollerBehavior::SimpleMaximum')
            && $workflow->maximum < 2) {
            Temporalio::Exception::Argument->throw(
                message => 'workflow_task_poller_behavior SimpleMaximum maximum'
                    . ' must be >= 2 for the workflow-task pool (got '
                    . $workflow->maximum . ')');
        }

        return (
            workflow_task_poller_behavior_spec => $workflow->_pack_spec,
            activity_task_poller_behavior_spec => $activity->_pack_spec,
            nexus_task_poller_behavior_spec    => $nexus->_pack_spec,
        );
    }

    method _build_worker_options ($keep) {
        return Temporalio::Core::FFI::WorkerOptions::build($keep,
            namespace            => $client->namespace,
            task_queue           => $task_queue,
            # One of None{build_id} / DeploymentBased / LegacyBuildIdBased per
            # the configured versioning strategy (spec §29.1).
            $self->_versioning_strategy,
            identity_override    => $identity_override,
            max_cached_workflows => $max_cached_workflows,

            # Slot suppliers (spec §29.2): an explicit tuner packs each pool's
            # supplier directly; otherwise synthesize a FixedSize tuner from the
            # max_concurrent_* slots (nexus is a fixed 100 in v0.1, spec 8.1).
            $self->_slot_supplier_options,

            # task_types (spec 8.1): workflows always; remote activities unless
            # no_remote_activities (spec 23.2); local activities only when the
            # worker registers BOTH workflows and activities, since LAs run on the
            # workflow worker and execute the same registered activity code. Core
            # delivers LA tasks through the same poll_activity_task path, so the
            # existing activity dispatcher handles them once the flag is set. This
            # flag was hardcoded 0 (#9), which left the local-activity path off:
            # core dropped every ScheduleLocalActivity command and the workflow
            # hung forever (and SEGV'd at teardown pre-B4). Matches sdk-ruby
            # (worker.rb: enable_local_activities = workflows && activities).
            enable_workflows         => 1,
            enable_local_activities  => (@$workflows && @$activities) ? 1 : 0,
            enable_remote_activities => $no_remote_activities ? 0 : 1,
            # Nexus serving (spec section 26.3, #11): enabled only when the worker
            # registers a Nexus service. Hardcoded 0 meant core never polled Nexus
            # tasks, so a handler worker could not serve operations and a caller's
            # execute_nexus_operation blocked forever. With the flag set AND the
            # Nexus poll loop wired in run(), the existing NexusDispatcher
            # services each task. A non-Nexus worker stays at 0 (unaffected).
            enable_nexus             => $self->_nexus_enabled,

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

            # Poller behaviors (spec §29.3): the behavior field is primary; an
            # explicitly-set legacy max_concurrent_*_task_polls overrides it with
            # SimpleMaximum(that). Resolved into *_poller_behavior_spec kwargs.
            $self->_poller_behavior_options,
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
    # drive BOTH the activity poll loop (spec 8.4) and the workflow poll loop
    # (spec 8.3) concurrently on the IO::Async loop. Returns when BOTH loops
    # drain — either because `shutdown` was called mid-run (initiate_shutdown
    # makes core return the ShutDown sentinel from both polls) or because core
    # shut the worker down. On the way out it finalizes and frees the worker
    # (the full graceful sequence deferred from `shutdown` per the P2.2 deadlock
    # note). T-wkr-4: shutdown mid-run causes run to return; a second shutdown is
    # a no-op.
    async method run () {
        $self->_assert_open;
        await $self->validate;     # _ensure_worker + pre-poll validate
        $is_running = 1;

        my $runtime           = $self->_runtime;
        my $activity_dispatcher = $self->_build_activity_dispatcher;
        my $activity_loop     = Temporalio::Worker::PollLoop->new(
            dispatcher  => $activity_dispatcher,
            poll_source => sub { return $self->_poll_activity_task },
            loop        => $runtime->loop,
        );
        my $workflow_dispatcher = $self->_build_workflow_dispatcher;
        my $workflow_loop     = Temporalio::Worker::PollLoop->new(
            dispatcher  => $workflow_dispatcher,
            poll_source => sub { return $self->_poll_workflow_activation },
            loop        => $runtime->loop,
        );

        # Nexus poll loop (spec section 26.3, #11): only wired when the worker
        # registers a Nexus service (matches the enable_nexus build flag). Core
        # rejects worker_poll_nexus_task when enable_nexus is off, so a non-Nexus
        # worker must NOT start this loop.
        my $nexus_loop;
        if ($self->_nexus_enabled) {
            $nexus_loop = Temporalio::Worker::PollLoop->new(
                dispatcher  => $self->_build_nexus_dispatcher,
                poll_source => sub { return $self->_poll_nexus_task },
                loop        => $runtime->loop,
            );
        }

        my $error;
        {
            local $@;
            # Drive every loop concurrently; each drains on its own ShutDown
            # sentinel. wait_all waits for ALL so no loop is abandoned mid task
            # (a still-running workflow/activity/Nexus completion must be sent).
            # wait_all never itself fails, so inspect each sub-future and surface
            # the first failure after all have settled.
            my @loops = ($activity_loop->run, $workflow_loop->run);
            push @loops, $nexus_loop->run if defined $nexus_loop;
            eval {
                await Future->wait_all(@loops);
                $_->is_failed and die(($_->failure)[0]) for @loops;
                1;
            } or $error = $@;
        }

        # Both loops have drained (sentinels seen). Make sure shutdown was
        # actually initiated (a loop may have exited because core shut down on
        # its own), then finalize + free. _finalize_and_free is idempotent.
        $self->_initiate_shutdown_once;
        await $self->_finalize_and_free;

        # Stop the sync-activity fork pool (reap its children) so no orphaned
        # worker processes linger after the worker stops.
        if (defined $activity_pool) {
            eval { $activity_pool->close; 1 };
            $activity_pool = undef;
        }

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
        $activity_pool = $self->_build_activity_pool;
        return Temporalio::Worker::ActivityDispatcher->new(
            registry       => $activity_registry,
            data_converter => $client->data_converter,
            task_queue     => $task_queue,
            client         => $client,
            loop           => $runtime->loop,
            pool           => $activity_pool,
            # The combined interceptor list drives the activity-inbound chain
            # the dispatcher now invokes per start (#10).
            interceptors   => $all_interceptors,
            completer      => sub ($completion_bytes) {
                return $self->_complete_activity_task($completion_bytes);
            },
            heartbeat_recorder => sub ($heartbeat_bytes) {
                return $self->_record_heartbeat($heartbeat_bytes);
            },
        );
    }

    # Build the sync-activity fork pool (spec section 9.4) only when the worker
    # registers at least one sync activity. The forked children MUST close the
    # runtime's wakeup fd (the read end of the eventfd/pipe the shim signals) —
    # a child holding it would corrupt the parent's completion drain. Heartbeats
    # a child records are relayed to the real synchronous FFI heartbeat here on
    # the parent side.
    method _build_activity_pool () {
        return undef unless $activity_registry->has_sync_activities;
        my $runtime = $self->_runtime;
        return Temporalio::Activity::Pool->new(
            loop          => $runtime->loop,
            max_workers   => $sync_activity_workers,
            registry      => $activity_registry,
            inherited_fhs => [ $runtime->read_handle ],
            heartbeat_relay => sub ($task_token, $heartbeat_bytes) {
                return $self->_record_heartbeat($heartbeat_bytes);
            },
        );
    }

    # Build the workflow dispatcher with the real completer (worker_complete_
    # workflow_activation over the callback bridge). The dispatcher caches one
    # Workflow::Runner per run, applies the codec boundary, and tears down a run
    # on RemoveFromCache (spec section 8.3).
    method _build_workflow_dispatcher () {
        return Temporalio::Worker::WorkflowDispatcher->new(
            registry       => $workflow_registry,
            data_converter => $client->data_converter,
            task_queue     => $task_queue,
            namespace      => $client->namespace,
            # Eager activity dispatch (spec section 23.2): the workflow-side flag
            # that suppresses do_not_eagerly_execute on scheduled activities.
            disable_eager_activity_execution => $disable_eager_activity_execution,
            # Worker versioning (spec §29.1): the per-workflow
            # :VersioningBehavior may only be reported when the worker runs in
            # versioned mode; core rejects a versioning_behavior otherwise
            # ("versioning behavior cannot be specified without deployment
            # options being set with versioned mode").
            report_versioning_behavior => $self->_in_versioned_mode,
            # Local activities run on the workflow worker and execute the worker's
            # own registered activity code, so the path is enabled only when BOTH
            # workflows and activities are registered (matches the build flag
            # above and sdk-ruby). When off, a workflow calling
            # execute_local_activity fails cleanly instead of hanging core (#9).
            local_activities_enabled => (@$workflows && @$activities) ? 1 : 0,
            # The combined interceptor list drives the workflow-inbound chain
            # each per-run Runner now invokes for execute_workflow / handle_signal
            # / handle_query / handle_update (#10).
            interceptors   => $all_interceptors,
            completer      => sub ($completion_bytes) {
                return $self->_complete_workflow_activation($completion_bytes);
            },
        );
    }

    # Build the Nexus dispatcher (spec section 26.2/26.3) with the real completer
    # (worker_complete_nexus_task over the callback bridge). Only constructed when
    # the worker registers a Nexus service; the dispatcher routes each polled
    # NexusTask to a registered operation and sends the NexusTaskCompletion (#11).
    method _build_nexus_dispatcher () {
        my $runtime = $self->_runtime;
        return Temporalio::Worker::NexusDispatcher->new(
            registry       => $nexus_registry,
            data_converter => $client->data_converter,
            task_queue     => $task_queue,
            client         => $client,
            loop           => $runtime->loop,
            completer      => sub ($completion_bytes) {
                return $self->_complete_nexus_task($completion_bytes);
            },
        );
    }

    # _nexus_enabled() — true when the worker registers at least one Nexus
    # service. Gates the enable_nexus build flag AND the Nexus poll loop so a
    # non-Nexus worker neither asks core to poll Nexus tasks nor drains a loop
    # (#11). Mirrors the registered-services rule the reference SDKs use.
    method _nexus_enabled () {
        return scalar(keys %{ $nexus_registry->services }) ? 1 : 0;
    }

    # _in_versioned_mode() — true when this worker reports per-workflow
    # versioning behavior to core (spec §29.1): deployment-based with
    # use_worker_versioning on, or the legacy build-id strategy.
    method _in_versioned_mode () {
        return 1 if defined $deployment_options
            && $deployment_options->use_worker_versioning;
        return 1 if $use_worker_versioning;
        return 0;
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

    # Issue worker_poll_workflow_activation over the callback bridge
    # ('worker_poll' kind): resolves with the serialized WorkflowActivation
    # bytes, or undef on the ShutDown sentinel (spec section 8.3 steps 1-2).
    method _poll_workflow_activation () {
        my $runtime = $self->_runtime;
        return Temporalio::Core::Callback->issue_async(
            $runtime, worker_poll => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::worker_poll_workflow_activation(
                    $worker_ptr, $user_data, $trampoline);
            });
    }

    # Issue worker_complete_workflow_activation over the callback bridge
    # ('worker' kind, fail-or-nothing). The completion bytes are passed as a
    # ByteArrayRef; @keep pins the buffer through the call (spec section 8.3
    # step 9).
    method _complete_workflow_activation ($completion_bytes) {
        my $runtime = $self->_runtime;
        my @keep;
        my ($data, $size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $completion_bytes);
        my $ref = Temporalio::Core::FFI::ByteArrayRef->new(
            data => $data, size => $size);
        my $f = Temporalio::Core::Callback->issue_async(
            $runtime, worker => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::worker_complete_workflow_activation(
                    $worker_ptr, $ref, $user_data, $trampoline);
            });
        return $f->on_ready(sub { @keep = (); undef $ref });
    }

    # Issue worker_poll_nexus_task over the callback bridge ('worker_poll' kind):
    # resolves with the serialized coresdk.nexus.NexusTask bytes, or undef on the
    # ShutDown sentinel. Same shape as the activity/workflow poll sources; only
    # driven when the worker registers a Nexus service (#11).
    method _poll_nexus_task () {
        my $runtime = $self->_runtime;
        return Temporalio::Core::Callback->issue_async(
            $runtime, worker_poll => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::worker_poll_nexus_task(
                    $worker_ptr, $user_data, $trampoline);
            });
    }

    # Issue worker_complete_nexus_task over the callback bridge ('worker' kind,
    # fail-or-nothing). The serialized NexusTaskCompletion is passed as a
    # ByteArrayRef; @keep pins the buffer through the call (#11).
    method _complete_nexus_task ($completion_bytes) {
        my $runtime = $self->_runtime;
        my @keep;
        my ($data, $size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $completion_bytes);
        my $ref = Temporalio::Core::FFI::ByteArrayRef->new(
            data => $data, size => $size);
        my $f = Temporalio::Core::Callback->issue_async(
            $runtime, worker => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::worker_complete_nexus_task(
                    $worker_ptr, $ref, $user_data, $trampoline);
            });
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

        # core's Worker::shutdown (driven by worker_finalize_shutdown) issues a
        # shutdown_worker RPC. If the server connection is reset/closed while
        # that RPC is in flight — expected during ordered teardown — the bridge
        # rejects with a transport-shaped Exception::Bridge. Tolerate ONLY that
        # (P10.0): the worker is being torn down regardless, so we must still
        # free it and return cleanly rather than reject `run` and dirty the
        # process exit. Any other failure is a real bug and is rethrown.
        my $finalize = Temporalio::Core::Callback->issue_async(
            $runtime, worker => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::worker_finalize_shutdown(
                    $ptr, $user_data, $trampoline);
            });
        my $err;
        {
            local $@;
            eval { await $finalize; 1 } or $err = $@;
        }
        if (defined $err
            && !Temporalio::Worker::_shutdown_error_is_tolerable($err))
        {
            # Free before rethrowing so a real finalize failure still releases
            # the native worker (DESTROY-safety, no leak).
            Temporalio::Core::FFI::worker_free($ptr);
            $worker_ptr  = undef;
            $worker_keep = undef;
            die $err;
        }

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

# Shutdown-time tolerance (P10.0): sdk-core's worker_finalize_shutdown drives a
# shutdown_worker RPC to the server AND does an Arc::try_unwrap on the core
# worker. Two teardown-shaped failures can surface here, both benign because the
# worker is going away regardless:
#
#   1. Transport teardown: the server connection is reset or closed while the
#      shutdown_worker RPC is in flight (common during ordered test teardown).
#      The bridge surfaces an Exception::Bridge whose message is the tonic
#      transport error (hyper ConnectionReset / broken pipe / connection closed).
#   2. Finalize Arc-refcount race (P10.0.4): try_unwrap expects exactly one
#      strong reference to the core worker. Under -j4 contention a Tokio poll
#      task still holding a worker-Arc clone may not have dropped by the time
#      finalize runs, so try_unwrap fails with "Cannot finalize, expected 1
#      reference, got N". This is a timing artifact of teardown, not a shutdown
#      bug.
#
# Core itself only WARNs on (1); both would otherwise reject the `run` future and
# dirty the process exit for every consumer. We swallow ONLY these teardown-shaped
# failures and still free the worker; any other bridge error (a real shutdown bug)
# is rethrown. Patterns kept deliberately narrow.
my @TOLERABLE_SHUTDOWN_PATTERNS = (
    qr/transport error/i,
    qr/connection\s*reset/i,
    qr/connection\s*closed/i,
    qr/connection\s*refused/i,
    qr/broken\s*pipe/i,
    qr/\bConnectionReset\b/,
    qr/\bBrokenPipe\b/,
    qr/Cannot finalize, expected \d+ reference/i,
);

# Declared at package scope with the fully-qualified glob: a bare `sub` in a
# file that uses `feature 'class'` would land in main::, not the class package
# (same reason the constructor wrapper below assigns *Temporalio::Worker::new).
sub Temporalio::Worker::_shutdown_error_is_tolerable ($err) {
    return 0 unless Scalar::Util::blessed($err);
    return 0 unless $err->isa('Temporalio::Exception::Bridge');
    my $message = $err->can('message') ? ($err->message // '') : '';
    for my $pat (@TOLERABLE_SHUTDOWN_PATTERNS) {
        return 1 if $message =~ $pat;
    }
    return 0;
}

# Wrap the generated constructor so an unrecognised kwarg surfaces as
# Exception::Argument (spec 8.1 — typos are caught, not passed to core). The
# native `class` `new` dies with a plain string before ADJUST can run, so the
# only clean intercept is around the constructor itself. Missing client /
# task_queue are handled in ADJUST (they default to undef).
{
    my $orig_new = Temporalio::Worker->can('new');
    no warnings 'redefine';
    # The max_concurrent_* slot kwargs that are mutually exclusive with an
    # explicit tuner (spec §29.2). Detected here (not in ADJUST) because
    # `class` params default silently, so "explicitly passed" is only visible
    # in the raw constructor args.
    my @SLOT_KWARGS = qw(
        max_concurrent_workflow_tasks
        max_concurrent_activities
        max_concurrent_local_activities
    );
    *Temporalio::Worker::new = sub ($class, %args) {
        if (defined $args{tuner}) {
            for my $kw (@SLOT_KWARGS) {
                next unless exists $args{tuner} && exists $args{$kw};
                Temporalio::Exception::Argument->throw(
                    message => "Temporalio::Worker->new: tuner is mutually"
                        . " exclusive with $kw (spec §29.2)");
            }
        }
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

=encoding utf8

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
    # await $worker->run;        # drives the activity + workflow poll loops
    await $worker->shutdown;     # initiate -> finalize -> free; idempotent

=head1 DESCRIPTION

The Temporal worker (spec section 8). Construction (spec 8.1) builds the
activity registry from the C<activities> list
(L<Temporalio::Worker::ActivityRegistry>) and the workflow registry from the
C<workflows> list (L<Temporalio::Worker::WorkflowRegistry>, spec 8.6 — each
class must declare one C<:Run>; duplicate types raise). A missing client or an
empty task queue raises L<Temporalio::Exception::Argument>.

C<run> (spec 8.2) drives the activity poll loop (spec 8.4) and the workflow
poll loop (spec 8.3) concurrently on the runtime's IO::Async loop, each backed
by a L<Temporalio::Worker::PollLoop> over its own poll source. The workflow
loop hands activations to a L<Temporalio::Worker::WorkflowDispatcher> (run_id
routing, per-run runner cache, codec boundary, RemoveFromCache eviction).
C<run> returns once both loops drain their C<ShutDown> sentinels, then
finalizes and frees the worker.

The WorkerOptions are marshalled by L<Temporalio::Core::FFI::WorkerOptions>
(the hand-packed C<TemporalCoreWorkerOptions> buffer proven in plan P0.10):
versioning is always C<None{build_id}>, the tuner is four C<FixedSize> slot
suppliers built from the C<max_concurrent_*> kwargs, task types enable
workflows + remote activities only, and the pollers are C<simple_maximum>.
Time-valued kwargs are seconds Perl-side and packed as milliseconds.
Defaults match the reference SDKs (sdk-ruby C<worker.rb>): cache 1000, slots
100, sticky 10s, heartbeat throttle 60s/30s, graceful shutdown 0s, pollers 5,
nonsticky-to-sticky ratio 0.2.

Eager activity dispatch (spec section 23.2) has two distinct knobs.
C<no_remote_activities> (default 0) is a bridge WorkerOptions field: the bridge
C<enable_remote_activities> is its negation, so a true value gives the worker no
remote activity poller (an eager activity declined for slots then times out
schedule-to-start). C<disable_eager_activity_execution> (default 0) is a
workflow-side flag threaded through the workflow dispatcher into each
L<Temporalio::Workflow::Runner>, where it sets C<do_not_eagerly_execute> on every
emitted C<ScheduleActivity> command.

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

=head1 METHODS

=head2 activity_registry

Accessor returning the C<activity_registry> value.

=head2 build_id

Accessor returning the worker's build id (the explicit C<build_id> kwarg, or the
MD5-of-C<%INC> per-process default; spec §29.1).

=head2 client

Accessor returning the C<client> value.

=head2 interceptors

Accessor returning the combined interceptor list (the client's interceptors
followed by the worker's own, spec section 27.2). This list drives the inbound
activity and workflow chains.

=head2 build_activity_inbound

C<< $worker->build_activity_inbound($root) >> folds the combined interceptor
list over C<$root> (a L<Temporalio::Worker::ActivityInbound>), first-listed
outermost, and returns the chain head (spec section 27.2).

=head2 build_workflow_inbound

C<< $worker->build_workflow_inbound($root) >> is the workflow-inbound analogue
of L</build_activity_inbound>.

=head2 is_shutdown

Accessor returning the C<is_shutdown> value.

=head2 nexus_registry

Accessor returning the C<nexus_registry> value (the L<Temporalio::Worker::NexusRegistry> built from C<nexus_services>).

=head2 run

Async. Runs the worker: starts the workflow and activity poll loops and returns a L<Future> that completes when the worker is shut down.

=head2 shutdown

Initiates a graceful shutdown of the worker's poll loops.

=head2 task_queue

Accessor returning the C<task_queue> value.

=head2 validate

Async. Validates the worker against the server (task-queue reachability) before polling; returns a L<Future>.

=head2 workflow_registry

Accessor returning the C<workflow_registry> value.

=head2 workflows

Accessor returning the C<workflows> value.

=cut
