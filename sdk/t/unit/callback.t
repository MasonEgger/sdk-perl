# ABOUTME: Tests Temporalio::Core::Callback (spec section 4.5): issue_async +
# ABOUTME: drain loop (T-cb-1..4), bridge failures, and the shutdown sentinel.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Scalar::Util ();
use FFI::Platypus::Buffer ();
use IO::Async::Loop ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Runtime ();

# Spec section 4.5: issue_async registers a pending Future keyed by a
# monotonic callback id and hands a shim user_data pair plus trampoline
# pointer to the invoke coderef. Completions are simulated by calling the
# trampoline directly through FFI with Perl-crafted ByteArrays
# (disable_free=1, so the drain loop's byte_array_free is a safe no-op);
# the drain loop then resolves the Future when the loop runs.

my $ffi = Temporalio::Core::FFI::ffi();

# Craft a *const TemporalCoreByteArray viewing $bytes. Everything pushed to
# @$keep stays alive until the drain loop has consumed the entry.
sub craft_byte_array ($bytes, $keep) {
    my $copy = $bytes;
    push @$keep, \$copy;
    my ($data, $size) = FFI::Platypus::Buffer::scalar_to_buffer($copy);
    my $record = Temporalio::Core::FFI::ByteArray->new(
        data         => $data,
        size         => $size,
        cap          => $size,
        disable_free => 1,
    );
    push @$keep, $record;
    return $ffi->cast(
        'record(Temporalio::Core::FFI::ByteArray)*' => 'opaque', $record);
}

# The worker_poll trampoline called through its *_callback_ptr address:
# (user_data, success *ByteArray, fail *ByteArray) -> void.
my $worker_poll = $ffi->function(
    Temporalio::Core::FFI::worker_poll_callback_ptr(),
    [ 'opaque', 'opaque', 'opaque' ] => 'void',
);

# Await $future while running $loop, but never hang the suite.
sub await_or_timeout ($loop, $future) {
    return Future->wait_any($future, $loop->timeout_future(after => 15))->get;
}

T2->subtest('T-cb-1: issue_async pending Future resolves with poll bytes' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my ($user_data, $trampoline_ptr);
    my $f = Temporalio::Core::Callback->issue_async(
        $runtime, worker_poll => sub ($ud, $ptr) {
            ($user_data, $trampoline_ptr) = ($ud, $ptr);
        });

    T2->isa_ok($f, 'Future');
    T2->ok(!$f->is_ready, 'Future starts pending');
    T2->ok(defined $user_data, 'invoke received a shim user_data pair');
    T2->is(
        $trampoline_ptr,
        Temporalio::Core::FFI::worker_poll_callback_ptr(),
        'invoke received the worker_poll trampoline pointer',
    );

    my @keep;
    $worker_poll->call(
        $user_data, craft_byte_array('poll-payload', \@keep), undef);
    T2->ok(!$f->is_ready, 'completion is queued, not delivered, until the loop runs');

    my $got = await_or_timeout($loop, $f);
    T2->is($got, 'poll-payload', 'Future resolves with the success bytes');

    $runtime->shutdown;
});

T2->subtest('worker_poll fail byte array fails the Future with Exception::Bridge' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my ($user_data);
    my $f = Temporalio::Core::Callback->issue_async(
        $runtime, worker_poll => sub ($ud, $ptr) { $user_data = $ud });

    my @keep;
    $worker_poll->call(
        $user_data, undef, craft_byte_array('poll exploded', \@keep));

    my $error = do {
        local $@;
        eval { await_or_timeout($loop, $f) };
        $@;
    };
    T2->ok(
        Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Bridge'),
        'Future fails with Temporalio::Exception::Bridge',
    ) or T2->diag($error);
    T2->is(
        Scalar::Util::blessed($error) ? $error->message : "$error",
        'poll exploded',
        'exception message is the fail byte array contents',
    );

    $runtime->shutdown;
});

T2->subtest('null/null worker_poll completion is the shutdown sentinel (undef)' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my ($user_data);
    my $f = Temporalio::Core::Callback->issue_async(
        $runtime, worker_poll => sub ($ud, $ptr) { $user_data = $ud });

    $worker_poll->call($user_data, undef, undef);

    my $got = await_or_timeout($loop, $f);
    T2->ok($f->is_done, 'sentinel resolves the Future successfully');
    T2->is($got, undef, 'sentinel resolves the Future with undef');

    $runtime->shutdown;
});

T2->subtest('T-cb-2: 1000 concurrent issue_async calls all resolve' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my (@futures, @keep);
    for my $i (0 .. 999) {
        my $user_data;
        push @futures, Temporalio::Core::Callback->issue_async(
            $runtime, worker_poll => sub ($ud, $ptr) { $user_data = $ud });
        $worker_poll->call(
            $user_data, craft_byte_array("payload-$i", \@keep), undef);
    }

    await_or_timeout($loop, Future->wait_all(@futures));

    my $resolved = grep { $_->is_done } @futures;
    T2->is($resolved, 1000, 'all 1000 Futures resolved successfully');

    my $mismatches = grep { $futures[$_]->get ne "payload-$_" } 0 .. 999;
    T2->is($mismatches, 0, 'every Future carries its own payload');

    $runtime->shutdown;
});

T2->subtest('T-cb-3: stale callback id is warned and dropped, not fatal' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $frees = 0;
    my $orig_free = \&Temporalio::Core::FFI::byte_array_free;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::byte_array_free =
        sub { $frees++; $orig_free->(@_) };
    use warnings 'redefine';

    # An entry whose callback_id was never issued: pair the queue with a
    # bogus id and fire the trampoline directly.
    my @keep;
    my $stale_user_data = Temporalio::Core::FFI::user_data_new(
        $runtime->queue_ptr, 999_999_999);
    $worker_poll->call(
        $stale_user_data, craft_byte_array('stale-bytes', \@keep), undef);

    # A valid call afterwards must still complete despite the stale entry.
    my $user_data;
    my $f = Temporalio::Core::Callback->issue_async(
        $runtime, worker_poll => sub ($ud, $ptr) { $user_data = $ud });
    $worker_poll->call(
        $user_data, craft_byte_array('valid-bytes', \@keep), undef);

    my @warnings;
    my $got = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        await_or_timeout($loop, $f);
    };

    T2->is($got, 'valid-bytes', 'valid completion resolves despite the stale entry');
    T2->is(scalar @warnings, 1, 'stale entry produces exactly one warning')
        or T2->diag(@warnings);
    T2->like(
        $warnings[0] // '',
        qr/stale callback id 999999999/,
        'warning names the stale callback id',
    );
    T2->is($frees, 2, 'both byte arrays freed (stale entry included)');

    $runtime->shutdown;
});

T2->subtest('T-cb-4: drain honors cap=256 per call and loops until empty' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my (@caps, @counts);
    my $orig_drain = \&Temporalio::Core::FFI::queue_drain;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::queue_drain = sub {
        push @caps, $_[2];
        my $count = $orig_drain->(@_);
        push @counts, $count;
        return $count;
    };
    use warnings 'redefine';

    # 300 completions queued before the loop runs: one wakeup must drain
    # them all (256 + 44), with a final call observing the empty queue.
    my (@futures, @keep);
    for my $i (0 .. 299) {
        my $user_data;
        push @futures, Temporalio::Core::Callback->issue_async(
            $runtime, worker_poll => sub ($ud, $ptr) { $user_data = $ud });
        $worker_poll->call(
            $user_data, craft_byte_array("chunk-$i", \@keep), undef);
    }

    await_or_timeout($loop, Future->wait_all(@futures));

    T2->ok(scalar @caps >= 2, 'queue_drain called more than once');
    my $bad_caps = grep { $_ != 256 } @caps;
    T2->is($bad_caps, 0, 'every drain call passes cap=256') or T2->note("@caps");

    my $total = 0;
    $total += $_ for @counts;
    T2->is($total, 300, 'all 300 entries drained across the calls');
    T2->is($counts[-1], 0, 'drain loops until a call returns 0');

    my $resolved = grep { $_->is_done } @futures;
    T2->is($resolved, 300, 'all 300 Futures resolved');

    $runtime->shutdown;
});

# Finding L17 / spec R20: the drain loop (Core/Callback.pm entry dispatch,
# spec-time :322-331) settles each pending Future (:463-467), which runs the
# awaiter's continuations synchronously; without per-entry isolation one
# dying continuation propagates out of the loop and strands every later
# completion in the chunk. Three completions land in one chunk; the middle
# one's continuation dies; the first and third must still resolve and the
# death must be logged, not propagated out of the drain.
T2->subtest('R20: a dying continuation does not strand later completions in the chunk' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    # Queue all three completions BEFORE running the loop so one wakeup
    # drains them as a single chunk (the stranding scenario).
    my (@futures, @keep);
    for my $i (0 .. 2) {
        my $user_data;
        push @futures, Temporalio::Core::Callback->issue_async(
            $runtime, worker_poll => sub ($ud, $ptr) { $user_data = $ud });
        $worker_poll->call(
            $user_data, craft_byte_array("entry-$i", \@keep), undef);
    }

    # The middle entry's continuation dies when the drain settles it.
    my $middle_ran = 0;
    $futures[1]->on_done(sub { $middle_ran++; die "continuation boom\n" });

    my (@warnings, $error);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        local $@;
        eval {
            await_or_timeout(
                $loop, Future->needs_all($futures[0], $futures[2]));
            1;
        } or $error = $@;
    }

    T2->is($error, undef, 'the death did not propagate out of the drain loop')
        or T2->diag("propagated: $error");
    T2->ok($futures[0]->is_done, 'entry before the dying one resolved');
    T2->ok($futures[1]->is_done, 'the dying entry itself still settled done');
    T2->ok($futures[2]->is_done, 'entry after the dying one is not stranded');
    T2->is(
        $futures[2]->is_done ? $futures[2]->get : undef,
        'entry-2',
        'the later entry carries its own payload',
    );
    T2->is($middle_ran, 1, 'the dying continuation ran exactly once');
    T2->ok(
        (scalar grep { /continuation boom/ } @warnings),
        'the death is captured and logged',
    ) or T2->diag("warnings: @warnings");

    $runtime->shutdown;
});

T2->subtest('unknown callback kind raises Exception::Argument' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $error = do {
        local $@;
        eval {
            Temporalio::Core::Callback->issue_async(
                $runtime, bogus_kind => sub { });
        };
        $@;
    };
    T2->ok(
        Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Argument'),
        'unknown kind raises Temporalio::Exception::Argument',
    ) or T2->diag($error);
    T2->like(
        Scalar::Util::blessed($error) ? $error->message : "$error",
        qr/bogus_kind/,
        'error names the unknown kind',
    );

    $runtime->shutdown;
});

T2->done_testing;
