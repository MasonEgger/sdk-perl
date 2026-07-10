# ABOUTME: Per-invocation activity context (spec section 9.3): info, heartbeat,
# ABOUTME: cancellation, payload converter. Looked up via the dynamically-scoped
# ABOUTME: $Temporalio::Activity::Context::CURRENT (NEVER `local` — F::AA panics).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

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
    # task_token, workflow_id, workflow_run_id, workflow_type, namespace.
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

    # The finished activity-outbound interceptor chain (spec R72, parity
    # finding 2), supplied by the ActivityDispatcher after it calls
    # inbound->init(root outbound). When set, info() and heartbeat() route
    # through it before the real work runs — the Perl form of sdk-python's
    # _ActivityInboundImpl.init installing outbound.info/outbound.heartbeat
    # on the context (worker/_activity.py:813-818, _interceptor.py:135-156).
    # undef (the fork-pool child's context and direct unit constructions)
    # means the direct behavior: pooled sync-activity heartbeats therefore
    # BYPASS the outbound chain, a documented spec §0 deviation — Python
    # routes them parent-side via register_heartbeater(ctx.heartbeat)
    # (_activity.py:857-865), but our pool relay carries already-serialized
    # ActivityHeartbeat BYTES, not Perl-level details, so there is nothing
    # chain-shaped to intercept parent-side.
    field $outbound :param = undef;

    # The set-on-cancel holder ({ details => CancellationDetails-or-undef })
    # the dispatcher writes the Cancel job's captured reason + details into
    # (spec R76). Shared BY REFERENCE with the dispatcher's running-activity
    # entry — Python's _ActivityCancellationDetailsHolder (activity.py:164-166)
    # — so a cancel landing after this context was built is still observable.
    # undef for direct constructions and the fork-pool child's context (the
    # holder does not cross the fork: a pooled sync body sees the frozen
    # `cancelled` flag and the R19 live-cancel relay but no details — a
    # documented spec section 0 deviation, like the heartbeat chain above).
    field $cancellation_details_holder :param = undef;

    # The worker runtime's metric meter (spec R83), injected by the
    # ActivityDispatcher on the async path. undef for the fork-pool child's
    # context and bare unit constructions: cross-process metrics are not
    # supported, matching Python's non-threaded sync activities
    # (activity.py:459-464).
    field $metric_meter :param = undef;

    # The lazily-wrapped context meter (see metric_meter below).
    field $context_metric_meter;

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
        my $converter = $data_converter->payload_converter;
        my @payloads  = map { $converter->to_payload($_) } @details;

        my $HB = Temporalio::Core::Proto::resolve('coresdk.ActivityHeartbeat');
        my $msg = $HB->new({
            task_token => $info->{task_token},
            details    => \@payloads,
        });

        my $error = $heartbeat_recorder->($msg->encode);
        if (defined $error && length $error) {
            Temporalio::Exception::Heartbeat->throw(
                message => "recording activity heartbeat failed: $error");
        }
        return;
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
times, and C<heartbeat_details>), mirroring the reference SDKs'
C<Activity::Info>.

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
chain, so pooled sync-activity heartbeats bypass interceptors (a documented
spec section 0 deviation).

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
sdk-python's C<activity.cancellation_details()>. The fork-pool child's
context always reports C<undef> (the holder does not cross the fork, a
documented spec section 0 deviation).

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

=item C<outbound>

(optional, default C<undef>) The finished activity-outbound interceptor
chain; when set, C<info> and C<heartbeat> route through it.

=item C<cancellation_details_holder>

(optional, default C<undef>) The dispatcher-shared set-on-cancel holder that
L</cancellation_details> reads (spec R76). C<undef> reports no details.

=item C<metric_meter>

(optional, default C<undef>) The worker runtime's metric meter (spec R83);
C<undef> makes L</metric_meter> raise (the fork-pool sync path).

=back

=cut
