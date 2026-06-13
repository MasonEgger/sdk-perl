# ABOUTME: Per-invocation activity context (spec section 9.3): info, heartbeat,
# ABOUTME: cancellation, payload converter. Looked up via the dynamically-scoped
# ABOUTME: $Temporalio::Activity::Context::CURRENT (NEVER `local` — F::AA panics).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();
use Temporalio::Exception::Heartbeat ();

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
    # (server-requested cancel or worker shutdown), supplied by the dispatcher.
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

    method info             { $info }
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
    method heartbeat (@details) {
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

=head2 cancellation

The L<Temporalio::Cancellation> that fires when this activity is cancelled.

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

=back

=cut
