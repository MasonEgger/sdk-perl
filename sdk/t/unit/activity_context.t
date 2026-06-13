# ABOUTME: Unit tests for Temporalio::Activity::Context + context() lookup
# ABOUTME: (spec section 9.3, T-act-7): dynamically-scoped context across an
# ABOUTME: await, heartbeat proto encoding/FFI spy, and cancellation exposure.
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;
use Syntax::Keyword::Dynamically;

use Temporalio::Activity ();
use Temporalio::Activity::Context ();
use Temporalio::Cancellation ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

# Build a Context with the minimum a unit test needs: a frozen info hashref,
# a real Cancellation, a data converter (default JSON payload converter), and
# a heartbeat recorder spy that captures the serialized ActivityHeartbeat
# proto bytes and returns whatever the test wants (undef = success, a string
# = a non-null bridge error).
sub make_context (%overrides) {
    my @recorded;
    my $recorder_return = $overrides{recorder_return};    # undef by default
    my $cancellation = $overrides{cancellation}
        // Temporalio::Cancellation->new;
    my $ctx = Temporalio::Activity::Context->new(
        info => {
            activity_id                    => 'act-1',
            activity_type                  => 'SayHello',
            attempt                        => 2,
            task_token                     => "tok\x00en",
            task_queue                     => 'demo',
            workflow_id                    => 'wf-1',
            workflow_run_id                => 'run-1',
            workflow_type                  => 'Greeting',
            namespace                      => 'default',
            heartbeat_details              => [],
            current_attempt_scheduled_time => undef,
            scheduled_time                 => undef,
            started_time                   => undef,
            ($overrides{info} ? %{ $overrides{info} } : ()),
        },
        cancellation     => $cancellation,
        data_converter   => Temporalio::Converter::Data->new,
        client           => $overrides{client},
        heartbeat_recorder => sub ($bytes) {
            push @recorded, $bytes;
            return $recorder_return;
        },
    );
    return ($ctx, \@recorded);
}

T2->subtest('context() outside an activity raises (spec 9.3)' => sub {
    my $err = exception_from(sub { Temporalio::Activity::context() });
    T2->ok(defined $err, 'context() with no current context dies');
    T2->isa_ok($err, 'Temporalio::Exception');
    T2->like("$err", qr/activity context/i, 'message mentions activity context');
});

T2->subtest('context() returns the dynamically-scoped ctx, even across await'
    => sub {
    my ($ctx) = make_context();
    my $seen_before;
    my $seen_after;
    my $delay = Future->new;

    my $body = async sub {
        $seen_before = Temporalio::Activity::context();
        await $delay;                 # the local-vs-dynamically panic point
        $seen_after = Temporalio::Activity::context();
        return 'done';
    };

    my $f;
    {
        # The dispatcher idiom (spec 9.3): dynamically, NEVER local.
        dynamically $Temporalio::Activity::Context::CURRENT = $ctx;
        $f = $body->();
    }
    # Resolve the await AFTER the dynamically block has exited — proves the
    # context is restored correctly inside the resumed async frame.
    $delay->done;

    T2->ok($f->is_ready, 'body future completed');
    T2->is(scalar $f->get, 'done', 'body returned');
    T2->is($seen_before, $ctx, 'context() before await is the scoped ctx');
    T2->is($seen_after,  $ctx, 'context() after await is the same ctx');

    # And once the scope is gone, context() raises again.
    my $err = exception_from(sub { Temporalio::Activity::context() });
    T2->ok(defined $err, 'context() raises again after scope exit');
});

T2->subtest('info() exposes the activity info fields (spec 9.3)' => sub {
    my ($ctx) = make_context();
    my $info = $ctx->info;
    T2->is($info->{activity_id},     'act-1',    'activity_id');
    T2->is($info->{activity_type},   'SayHello', 'activity_type');
    T2->is($info->{attempt},         2,          'attempt');
    T2->is($info->{workflow_id},     'wf-1',     'workflow_id');
    T2->is($info->{workflow_run_id}, 'run-1',    'workflow_run_id');
    T2->is($info->{task_queue},      'demo',     'task_queue');
});

T2->subtest('cancellation is a Temporalio::Cancellation (spec 9.3)' => sub {
    my $cancellation = Temporalio::Cancellation->new;
    my ($ctx) = make_context(cancellation => $cancellation);
    T2->isa_ok($ctx->cancellation, 'Temporalio::Cancellation');
    T2->is($ctx->cancellation, $cancellation, 'returns the injected token');
    T2->is($ctx->cancellation->is_cancelled, 0, 'not cancelled initially');
    $cancellation->cancel;
    T2->is($ctx->cancellation->is_cancelled, 1, 'cancel propagates');
});

T2->subtest('heartbeat encodes a coresdk.ActivityHeartbeat proto (T-act-7)'
    => sub {
    my ($ctx, $recorded) = make_context();
    $ctx->heartbeat('progress', { pct => 50 });

    T2->is(scalar @$recorded, 1, 'recorder called once');

    my $HB = Temporalio::Core::Proto::resolve('coresdk.ActivityHeartbeat');
    my $msg = $HB->decode($recorded->[0]);
    T2->is($msg->task_token, "tok\x00en", 'task_token from info');

    my $details = $msg->details;
    T2->is(scalar @$details, 2, 'two detail payloads encoded');

    # Decode the payloads back through the same converter to confirm
    # round-trip fidelity (from_payload returns a single value).
    my $dc = Temporalio::Converter::Data->new;
    my $first = $dc->payload_converter->from_payload($details->[0]);
    T2->is($first, 'progress', 'first detail round-trips');
    my $second = $dc->payload_converter->from_payload($details->[1]);
    T2->is($second->{pct}, 50, 'second detail round-trips');
});

T2->subtest('heartbeat with no details still records (spec 9.3)' => sub {
    my ($ctx, $recorded) = make_context();
    $ctx->heartbeat();
    T2->is(scalar @$recorded, 1, 'recorder called for an empty heartbeat');
    my $HB = Temporalio::Core::Proto::resolve('coresdk.ActivityHeartbeat');
    my $msg = $HB->decode($recorded->[0]);
    T2->is(scalar @{ $msg->details }, 0, 'no detail payloads');
});

T2->subtest('heartbeat raises Heartbeat on a non-null bridge return (T-act-7)'
    => sub {
    my ($ctx) = make_context(recorder_return => 'bridge boom');
    my $err = exception_from(sub { $ctx->heartbeat('x') });
    T2->ok(defined $err, 'a non-null return raises');
    T2->isa_ok($err, 'Temporalio::Exception::Heartbeat');
    T2->like("$err", qr/bridge boom/, 'bridge message surfaced');
});

T2->done_testing;
