# ABOUTME: Per-invocation activity context (spec section 9.3): info, heartbeat,
# ABOUTME: cancellation, payload converter. Looked up via the dynamically-scoped
# ABOUTME: $Temporalio::Activity::Context::CURRENT (NEVER `local` — F::AA panics).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Heartbeat ();
use Temporalio::Exception::Runtime ();
use Temporalio::Worker::Interceptor ();   # Input classes for the outbound chain

class Temporalio::Activity::Context {
    # The currently-running activity's context, set by the dispatcher with
    # `dynamically $Temporalio::Activity::Context::CURRENT = $ctx;` around the
    # activity body (spec section 9.3 — `local` panics across an await under
    # Future::AsyncAwait, so the dispatcher MUST use Syntax::Keyword::Dynamically).
    our $CURRENT;

    # ActivityInfo (spec section 9.3): a frozen hashref built by the dispatcher
    # from the ActivityTask start job. Fields mirror the reference SDKs'
    # Activity::Info (sdk-ruby activity/info.rb, sdk-python activity.Info):
    # activity_id, activity_type, attempt, current_attempt_scheduled_time,
    # heartbeat_timeout, heartbeat_details, schedule_to_close_timeout,
    # scheduled_time, start_to_close_timeout, started_time, task_queue,
    # task_token, workflow_id, workflow_run_id, workflow_type, namespace,
    # priority, retry_policy (spec R85; the latter two stay proto
    # sub-messages, undef when the start job omits them).
    field $info :param;

    # A Temporalio::Cancellation that fires when the activity is cancelled
    # for ANY cause — explicit server cancel, worker shutdown, pause, reset,
    # timeout, or not-found — supplied by the dispatcher. The token alone does
    # not say WHICH cause; cancellation_details below does (spec R76, parity
    # worker finding 2 / activity+conversion finding 3: this comment used to
    # conflate server-cancel with worker-shutdown as if they were the only two
    # and interchangeable; sdk-python worker/_activity.py:221-226 delivers the
    # cause alongside the cancel and bodies branch on it).
    field $cancellation :param;

    # The worker's Temporalio::Converter::Data — heartbeat() converts details
    # through its payload converter (matching sdk-ruby OutboundImplementation,
    # which calls convert_to_payload_array(data_converter, details)).
    field $data_converter :param;

    # Back-reference to the worker's client (spec section 9.3 `->client`).
    field $client :param = undef;

    # A coderef ($serialized_activity_heartbeat_bytes) -> $error_or_undef. The
    # dispatcher supplies one that performs the synchronous FFI
    # worker_record_activity_heartbeat over the worker pointer and returns the
    # decoded bridge error string (or undef on success). Decoupling the FFI
    # behind a coderef keeps Context unit-testable without a live worker and
    # lets the sync-activity fork pool (P2.5) substitute a pipe relay.
    field $heartbeat_recorder :param;

    # A coderef (@details) -> () invoked with the RAW, unconverted heartbeat
    # detail values, AFTER that heartbeat's payload conversion has succeeded
    # (step F6; spec I7 direction B, closes GitHub #7 half B). Pure
    # observation: the real recording still goes through heartbeat_recorder
    # above (bytes-based, unaffected). The fork-pool child wires one that
    # relays the Perl-level details to the parent over the pool's control
    # channel, so the parent's ActivityOutbound chain can observe them
    # structured (not opaque bytes) before the pre-encoded bytes reach the
    # real heartbeat_relay: see Temporalio::Activity::Pool's
    # `_child_dispatch`/`_on_control_frame`.
    # undef (every other construction) means no such relay.
    field $heartbeat_details_recorder :param = undef;

    # The finished activity-outbound interceptor chain (spec R72, parity
    # finding 2), supplied by the ActivityDispatcher after it calls
    # inbound->init(root outbound). When set, info() and heartbeat() route
    # through it before the real work runs — the Perl form of sdk-python's
    # _ActivityInboundImpl.init installing outbound.info/outbound.heartbeat
    # on the context (worker/_activity.py:813-818, _interceptor.py:135-156).
    # undef for direct unit constructions. The fork-pool child's context also
    # gets undef here (interceptor OBJECTS do not cross the fork; they live
    # only in the parent), but pooled sync-activity heartbeats are NOT
    # bypassed: Temporalio::Activity::Pool relays the RAW Perl-level details
    # to the parent (via heartbeat_details_recorder below) and runs the SAME
    # finished outbound chain there, parent-side, before forwarding the
    # pre-encoded bytes to the real heartbeat_relay (spec I7 direction B,
    # closes GitHub #7 half B; was a documented spec §0 deviation before I7).
    field $outbound :param = undef;

    # The set-on-cancel holder ({ details => CancellationDetails-or-undef })
    # the dispatcher writes the Cancel job's captured reason + details into
    # (spec R76). Shared BY REFERENCE with the dispatcher's running-activity
    # entry — Python's _ActivityCancellationDetailsHolder (activity.py:164-166)
    # — so a cancel landing after this context was built is still observable.
    # undef for direct constructions. The fork-pool child builds its OWN
    # per-invocation holder (Activity::Pool's `_child_dispatch`): the holder
    # OBJECT does not cross the fork, but the cancel's reason + six boolean
    # causes now do, relayed down the pool's control channel and decoded into
    # a fresh Temporalio::Activity::CancellationDetails in-child (spec I7
    # direction A, closes GitHub #7 half A; was a documented spec §0
    # deviation before I7: a pooled body saw only the frozen `cancelled`
    # flag and the R19 live-cancel relay, no details).
    field $cancellation_details_holder :param = undef;

    # The dispatcher-shared Temporalio::Common::Event that fires when the
    # worker BEGINS shutdown (spec R84, parity activity/conversion finding 4:
    # the cancellation token above used to be the only signal, folding worker
    # shutdown into plain cancellation so a body could not tell them apart or
    # await shutdown independently). Set by ActivityDispatcher->notify_shutdown
    # at shutdown-begin, BEFORE core's graceful-period cancels propagate —
    # Python's worker_shutdown_event on _Context (activity.py:200,400-438,
    # worker/_activity.py:185-187). undef for direct constructions. The
    # fork-pool child gets a Temporalio::Activity::ChildShutdownEvent instead
    # of this SAME shared event object (which cannot cross the fork): it
    # exposes the identical is_set/set/wait surface, backed by a poll of the
    # pool's control channel for the 'shutdown' frame
    # Pool->notify_shutdown broadcasts (spec I7 direction A, closes GitHub #7
    # half A; was a documented spec §0 deviation before I7: is_worker_shutdown
    # stayed permanently false in a pooled body).
    field $worker_shutdown_event :param = undef;

    # The worker runtime's metric meter (spec R83), injected by the
    # ActivityDispatcher on the async path. undef for the fork-pool child's
    # context and bare unit constructions: cross-process metrics are not
    # supported, matching Python's non-threaded sync activities
    # (activity.py:459-464).
    field $metric_meter :param = undef;

    # The lazily-wrapped context meter (see metric_meter below).
    field $context_metric_meter;

    # The lazily-built logging-detail hash (see log_details below).
    field $log_details;

    # log_details() -> a hashref of the contextual fields worth attaching to
    # every log line an activity body emits (spec R96, parity
    # activity/conversion finding 6): the exact set Python's activity
    # LoggerAdapter embeds via Info._logger_details (activity.py:148-159,
    # surfaced through the adapter at activity.py:479-537). Built ONCE from
    # the existing frozen Info on first access and cached, mirroring
    # _Context.logger_details (activity.py:229-232). The resolved direction
    # for finding 6: Perl has no single standard logging framework, so the
    # SDK exposes the details and documents the caller-logger wiring pattern
    # in POD instead of mandating (or depending on) a logging framework.
    method log_details {
        return $log_details //= do {
            my $current = $self->info;
            +{ map { $_ => $current->{$_} } qw(
                activity_id activity_type attempt namespace task_queue
                workflow_id workflow_run_id workflow_type
            ) };
        };
    }

    # metric_meter() -> the activity metric meter (spec R83): the runtime
    # meter carrying the namespace/task_queue/activity_type attribute set,
    # built lazily on first access (Python parity: activity.py:247,461-472).
    # Raises when no runtime meter was injected (the fork-pool sync path).
    method metric_meter {
        if (!defined $metric_meter) {
            Temporalio::Exception::Runtime->throw(
                message => 'metric meter is not available in fork-pool sync'
                         . ' activities (cross-process metrics are not'
                         . ' supported; Python parity: activity.py:459)');
        }
        return $context_metric_meter //=
            $metric_meter->with_additional_attributes({
                namespace     => $info->{namespace},
                task_queue    => $info->{task_queue},
                activity_type => $info->{activity_type},
            });
    }

    # is_worker_shutdown() -> bool: true once the worker has begun shutting
    # down (spec R84; Python parity: activity.is_worker_shutdown(),
    # activity.py:400-409). Distinct from is_cancelled on the cancellation
    # token: a plain server cancel leaves this false, and shutdown flips it
    # BEFORE the shutdown-driven cancel arrives.
    method is_worker_shutdown () {
        return 0 unless defined $worker_shutdown_event;
        return $worker_shutdown_event->is_set;
    }

    # wait_for_worker_shutdown() -> Future resolving when the worker begins
    # shutdown (spec R84; Python parity: activity.wait_for_worker_shutdown(),
    # activity.py:412-418). With no dispatcher event (the fork-pool child /
    # direct constructions) the returned future is pending forever — shutdown
    # is not observable there, mirroring the cancellation_details fork
    # deviation.
    method wait_for_worker_shutdown () {
        return Future->new unless defined $worker_shutdown_event;
        return $worker_shutdown_event->wait;
    }

    # cancellation_details() -> Temporalio::Activity::CancellationDetails or
    # undef while the activity has not been cancelled (Python parity:
    # activity.cancellation_details(), activity.py:315-317).
    method cancellation_details {
        return undef unless defined $cancellation_details_holder;
        return $cancellation_details_holder->{details};
    }

    # info() (spec section 9.3): the frozen info hashref, routed through the
    # outbound chain when one is installed (Python parity: every
    # activity.info() call goes through ActivityOutboundInterceptor.info).
    # The Input carries only the private `_root` returning the hashref
    # (Python's info() takes no input): the R71/R72 Input-everywhere
    # deviation.
    method info {
        return $info unless defined $outbound;
        return $outbound->info(
            Temporalio::Worker::Interceptor::Input::Info->new(
                _root => sub { $info },
            ));
    }
    method cancellation     { $cancellation }
    method client           { $client }
    method data_converter   { $data_converter }

    method payload_converter { $data_converter->payload_converter }

    # heartbeat(@details) (spec section 9.3, T-act-7): convert each detail
    # value to a Payload, wrap them in a coresdk.ActivityHeartbeat{task_token,
    # details} proto, serialize, and hand the bytes to the recorder. A
    # non-null/defined recorder return (the bridge's error byte array contents)
    # raises Temporalio::Exception::Heartbeat. Throttling is core's job (the
    # worker options' heartbeat-throttle intervals), not the Perl layer's.
    #
    # The payload codec chain is async (Future-returning) in this SDK; heartbeat
    # is a synchronous call (the reference SDKs' heartbeat is sync too), so v0.1
    # applies only the synchronous payload converter here — a codec chain on
    # heartbeat details is deferred until a sync-friendly codec path exists.
    #
    # With an outbound chain installed (spec R72) the call routes through it
    # first — details ride the Input's writable `args` field (Python's
    # *details) so a wrapper can observe or rewrite them — and the chain ROOT
    # performs the recording below via the input's `_root` coderef. A wrapper
    # that does not delegate replaces the recording entirely.
    method heartbeat (@details) {
        return $self->_record_heartbeat(@details) unless defined $outbound;
        return $outbound->heartbeat(
            Temporalio::Worker::Interceptor::Input::Heartbeat->new(
                args  => [@details],
                _root => sub { $self->_record_heartbeat(@{ $_[0]->args }) },
            ));
    }

    method _record_heartbeat (@details) {
        # Encode FIRST, relay the raw details SECOND (step F6). The two go
        # out as separate frames on the fork pool's control channel, and the
        # parent pairs them by parking the details until the bytes arrive
        # (Activity::Pool's 'hbd'/'hb' cases), so a details frame sent for a
        # heartbeat that then fails to encode would sit parked and pair with
        # a LATER heartbeat's bytes, making the parent re-encode the earlier
        # heartbeat's args in place of the later one's. Ordering the two
        # calls is the whole fix: a failed encode now sends neither frame,
        # so nothing is ever parked without its own bytes following
        # immediately. The alternative (tagging both frames with a
        # per-invocation sequence number and pairing only on a match) buys
        # nothing here, because the child is synchronous: it cannot have two
        # heartbeats in flight at once, so "the details immediately before
        # these bytes" is already an exact identification once the orphan
        # case is gone.
        my $bytes =
            encode_heartbeat_bytes($data_converter, $info->{task_token},
                @details);
        $heartbeat_details_recorder->(@details)
            if defined $heartbeat_details_recorder;

        my $error = $heartbeat_recorder->($bytes);
        if (defined $error && length $error) {
            Temporalio::Exception::Heartbeat->throw(
                message => "recording activity heartbeat failed: $error");
        }
        return;
    }

    # encode_heartbeat_bytes($data_converter, $task_token, @details) -> bytes
    # (spec I7 REFACTOR sub-step 6, closes GitHub #7): the ONE parent-side
    # place that converts heartbeat detail values into an encoded
    # coresdk.ActivityHeartbeat frame. _record_heartbeat above calls it for
    # the async path; Temporalio::Activity::Pool's parent-side chain root
    # (_on_control_frame's 'hb' case) calls it fully-qualified for the
    # pooled path, so a heartbeat an ActivityOutbound interceptor rewrites
    # is encoded from the SAME (possibly-rewritten) args on both paths
    # instead of the pooled path relaying the child's pre-rewrite bytes.
    # A package sub, not a method: the pool has no Context instance to call
    # it on.
    sub encode_heartbeat_bytes ($data_converter, $task_token, @details) {
        my $converter = $data_converter->payload_converter;
        my @payloads  = map { $converter->to_payload($_) } @details;

        my $HB = Temporalio::Core::Proto::resolve('coresdk.ActivityHeartbeat');
        my $msg = $HB->new({
            task_token => $task_token,
            details    => \@payloads,
        });
        return $msg->encode;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Activity::Context - per-invocation activity execution context

=head1 SYNOPSIS

    use Temporalio::Activity;

    # Inside an activity body:
    my $ctx = Temporalio::Activity::context();
    my $info = $ctx->info;                 # ActivityInfo hashref
    $ctx->heartbeat('halfway', { pct => 50 });
    my $cancel = $ctx->cancellation;       # Temporalio::Cancellation

=head1 DESCRIPTION

The execution context for one activity invocation (spec section 9.3). The
activity dispatcher constructs one per task and scopes it for the duration of
the body with L<Syntax::Keyword::Dynamically>:

    dynamically $Temporalio::Activity::Context::CURRENT = $ctx;
    await $activity_body->(@args);

B<Critical:> the dispatcher MUST use C<dynamically>, never Perl's built-in
C<local> — C<local> panics across an C<await> point under
L<Future::AsyncAwait> (spec section 16.1). Activity bodies retrieve the
context with the package function L<Temporalio::Activity/context>.

=head1 METHODS

=head2 info

The frozen ActivityInfo hashref (C<activity_id>, C<activity_type>,
C<attempt>, C<task_token>, C<task_queue>, C<workflow_id>,
C<workflow_run_id>, C<workflow_type>, C<namespace>, the schedule/start
times, C<heartbeat_details>, C<priority>, and C<retry_policy>), mirroring
the reference SDKs' C<Activity::Info>. C<priority> and C<retry_policy>
(spec R85) are the C<temporal.api.common.v1.Priority> /
C<temporal.api.common.v1.RetryPolicy> proto sub-messages from the start
job, or C<undef> when the server sent neither; their field names match
sdk-python's C<Priority> and C<RetryPolicy> value types.

=head2 log_details

A hashref of the contextual fields worth attaching to every log line the
activity body emits: C<activity_id>, C<activity_type>, C<attempt>,
C<namespace>, C<task_queue>, C<workflow_id>, C<workflow_run_id>, and
C<workflow_type> (spec R96). This is the exact field set sdk-python's
C<activity.LoggerAdapter> embeds in each message (activity.py:479-537).
Built once from L</info> on first access and cached for the invocation, so
it reflects the current attempt.

The SDK does not mandate or depend on a logging framework; Perl has no
single standard one. Wire the details into whatever logger the application
already uses. With L<Log::Any>, either pass them per message:

    use Log::Any qw($log);

    async sub my_activity (@args) {
        my $ctx = Temporalio::Activity::context();
        $log->info('processing started', $ctx->log_details);
        ...
    }

or bind them once through Log::Any's context hash so every line in the
body carries them:

    my $details = Temporalio::Activity::context()->log_details;
    $log->context->{$_} = $details->{$_} for keys %$details;
    $log->info('processing started');   # carries the activity fields

The same hashref works as the structured-fields argument of any logger
that accepts key/value context (Log::Contextual, Mojo::Log context, a
plain C<sprintf> over the pairs).

=head2 heartbeat(@details)

Converts each detail value through the payload converter, wraps them in a
C<coresdk.ActivityHeartbeat> proto with this activity's C<task_token>,
serializes it, and hands the bytes to the heartbeat recorder (which performs
the synchronous bridge call C<worker_record_activity_heartbeat>). A non-empty
recorder return raises L<Temporalio::Exception::Heartbeat>. Heartbeat
throttling is handled by core, not this layer.

When the dispatcher installed an activity-outbound interceptor chain (spec
R72), both C<heartbeat> and C<info> route through it first, matching
sdk-python's C<ActivityOutboundInterceptor>; the chain root performs the real
recording (or returns the real info). The fork-pool child's context has no
chain object of its own (interceptors live only in the parent process), but a
pooled sync-activity heartbeat still runs the SAME finished chain: the child
relays the raw Perl-level details to the parent over the pool's control
channel, and the parent's chain root re-encodes the chain's (possibly
interceptor-rewritten) output args via L</encode_heartbeat_bytes> before
forwarding to the real recorder, so a rewrite is honored identically on both
paths (spec I7 direction B, closes GitHub #7 half B; REFACTOR sub-step 6).

=head2 encode_heartbeat_bytes($data_converter, $task_token, @details)

A package sub, not a method: converts heartbeat detail values into an
encoded C<coresdk.ActivityHeartbeat> frame. The ONE parent-side entry point
(spec I7 REFACTOR sub-step 6, closes GitHub #7) both L</heartbeat> above (the
async path) and L<Temporalio::Activity::Pool>'s parent-side chain root (the
pooled path) call to produce the bytes handed to the real heartbeat recorder,
so both paths encode identically.

=head2 cancellation

The L<Temporalio::Cancellation> that fires when this activity is cancelled
for any cause: an explicit server cancel, worker shutdown, pause, reset,
timeout, or not-found. The token itself carries no cause; call
L</cancellation_details> to find out which (spec R76 — this section used to
present server-cancel and worker-shutdown as the interchangeable whole of
cancellation).

=head2 cancellation_details

The L<Temporalio::Activity::CancellationDetails> captured from the C<Cancel>
activity task (its reason plus the six boolean causes), or C<undef> while the
activity has not been cancelled. Set once when the cancel arrives; mirrors
sdk-python's C<activity.cancellation_details()>. The fork-pool child builds
its own per-invocation holder from the reason + six boolean causes relayed
down the pool's control channel alongside the cancel (spec I7 direction A,
closes GitHub #7 half A), so a pooled body observes the same details an async
body would for the same cancel. C<undef> for a direct construction with no
holder.

=head2 is_worker_shutdown

True once the worker has begun shutting down (spec R84; Python parity:
C<activity.is_worker_shutdown()>). Distinct from the cancellation token: an
ordinary cancel leaves this false, and worker shutdown flips it at
shutdown-begin, before the shutdown-driven cancel propagates. The fork-pool
child's context is backed by a L<Temporalio::Activity::ChildShutdownEvent>
that polls the pool's control channel for the 'shutdown' frame
C<< Pool->notify_shutdown >> broadcasts (spec I7 direction A, closes GitHub
#7 half A), so this flips true in a pooled body too. Stays false for a
direct construction with no event.

=head2 wait_for_worker_shutdown

A L<Future> that resolves when the worker begins shutdown (spec R84; Python
parity: C<activity.wait_for_worker_shutdown()>). Already resolved when
shutdown has begun. On a context without a shutdown event (a direct
construction) the returned Future never resolves.

=head2 metric_meter

The activity metric meter (spec R83): a
L<Temporalio::Runtime::MetricMeter::Meter> backed by the worker runtime's
configured exporter, carrying the C<namespace>, C<task_queue>, and
C<activity_type> attributes (Python parity: C<activity.metric_meter()>).
Raises L<Temporalio::Exception::Runtime> on the fork-pool child's context,
where cross-process metrics are not supported (Python raises the same for
non-threaded sync activities).

=head2 client / data_converter / payload_converter

Readers for the worker's client, the data converter, and the payload
converter respectively.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Activity::Context->new(
        info => ...,
        cancellation => ...,
        data_converter => ...,
        client => ...,
        heartbeat_recorder => ...,
    );

Constructs a Temporalio::Activity::Context. Named parameters:

=over 4

=item C<info>

(required)

=item C<cancellation>

(required)

=item C<data_converter>

(required)

=item C<client>

(optional, default C<undef>)

=item C<heartbeat_recorder>

(required)

=item C<heartbeat_details_recorder>

(optional, default C<undef>) A coderef invoked with the RAW, unconverted
C<@details> (spec I7 direction B), for pure observation; the fork-pool child
wires one to relay Perl-level heartbeat details to the parent's
ActivityOutbound chain. It is invoked only B<after> that heartbeat's own
payload conversion has succeeded (step F6), so a heartbeat that fails to
encode never announces details the real recording will not follow: see
L<Temporalio::Activity::Pool/Frame pairing guarantees (step F6)>.

=item C<outbound>

(optional, default C<undef>) The finished activity-outbound interceptor
chain; when set, C<info> and C<heartbeat> route through it.

=item C<cancellation_details_holder>

(optional, default C<undef>) The dispatcher-shared set-on-cancel holder that
L</cancellation_details> reads (spec R76). C<undef> reports no details.

=item C<worker_shutdown_event>

(optional, default C<undef>) The dispatcher-shared
L<Temporalio::Common::Event> fired at worker shutdown-begin (spec R84);
C<undef> means shutdown is not observable (L</is_worker_shutdown> stays
false, L</wait_for_worker_shutdown> never resolves).

=item C<metric_meter>

(optional, default C<undef>) The worker runtime's metric meter (spec R83);
C<undef> makes L</metric_meter> raise (the fork-pool sync path).

=back

=cut
