# ABOUTME: Asserts the runtime shutdown ordering barrier -> fail-pending ->
# ABOUTME: queue-free (spec R1+R21; findings L1 and L18).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();
use FFI::Platypus::Buffer ();
use IO::Async::Loop ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Runtime ();

# Global Requirement 5 guard-assertion tests for the shutdown pass (the race
# window itself is not deterministically executable). Code trace:
#
# - Finding L1 (R1): Runtime.pm:252-253 freed the shim completion queue with
#   no barrier while async bridge calls could still be in flight. The shim
#   side can then push into freed memory: queue_free's contract demands "no
#   further pushes" (ext/temporalio-perl-bridge/src/lib.rs:1684-1689), yet
#   the single-shot trampoline completion path (ext:206-227) and the kind-7
#   forwarded-log trampoline (ext:368-392) both dereference the queue pointer
#   they were handed whenever core completes late.
# - Finding L18 (R21): $pending (Core/Callback.pm:250) was never failed or
#   cleared at shutdown; close (Core/Callback.pm:472-477) tears down only the
#   fds, so any future awaited across shutdown hung forever.
#
# The fix sequences shutdown as barrier (drain in-flight completions, bounded
# by $Temporalio::Runtime::SHUTDOWN_DRAIN_TIMEOUT) -> fail-pending (typed
# shutdown error on every still-pending future) -> queue-free. These tests
# assert that observable order.

my $ffi = Temporalio::Core::FFI::ffi();

# Craft a *const TemporalCoreByteArray viewing $bytes (disable_free=1 so the
# drain loop's byte_array_free is a safe no-op). Everything pushed to @$keep
# stays alive until the drain has consumed the entry.
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
# (user_data, success *ByteArray, fail *ByteArray) -> void. Calling it from
# the main thread stands in for core's Tokio-thread completion: it enqueues
# the entry on the runtime's queue exactly as a live completion would.
my $worker_poll = $ffi->function(
    Temporalio::Core::FFI::worker_poll_callback_ptr(),
    [ 'opaque', 'opaque', 'opaque' ] => 'void',
);

# Issue a synthetic outstanding bridge call: registers a pending future and
# captures the shim user_data pair without ever calling into core.
sub issue_synthetic ($runtime, $user_data_ref) {
    return Temporalio::Core::Callback->issue_async(
        $runtime, worker_poll => sub ($ud, $ptr) { $$user_data_ref = $ud });
}

T2->subtest('R1: queue free deferred until an enqueued completion settles' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my @order;
    my $orig_free = \&Temporalio::Core::FFI::queue_free;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::queue_free =
        sub { push @order, 'queue-free'; $orig_free->(@_) };
    use warnings 'redefine';

    my $user_data;
    my $f = issue_synthetic($runtime, \$user_data);
    $f->on_ready(sub { push @order, 'callback-settled' });

    # Complete the callback but never run the loop: the entry sits enqueued
    # and undrained when shutdown begins, exactly the L1 window.
    my @keep;
    $worker_poll->call(
        $user_data, craft_byte_array('late-completion', \@keep), undef);
    T2->ok(!$f->is_ready, 'completion is enqueued but undrained pre-shutdown');

    $runtime->shutdown;

    T2->ok($f->is_done, 'shutdown barrier drained the in-flight completion')
        or T2->diag('future state: ' . ($f->is_ready ? 'ready' : 'pending'));
    T2->is($f->is_done ? $f->get : undef, 'late-completion',
        'future resolved with the real completion payload, not an error');
    T2->is(\@order, [ 'callback-settled', 'queue-free' ],
        'callback settles BEFORE the completion queue is freed');
});

T2->subtest('R21: pending future fails with a typed shutdown error, no hang' => sub {
    # Shrink the barrier so the never-completing callback times out fast.
    local $Temporalio::Runtime::SHUTDOWN_DRAIN_TIMEOUT = 0.2;

    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $user_data;
    my $f = issue_synthetic($runtime, \$user_data);

    # shutdown must return (bounded barrier) with the future settled: a
    # prompt, catchable failure instead of the L18 forever-hang.
    $runtime->shutdown;

    T2->ok($f->is_ready, 'pending future is settled by shutdown (no hang)');
    my $error = $f->is_ready ? $f->failure : undef;
    T2->ok(
        Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Runtime'),
        'future failed with the typed Temporalio::Exception::Runtime',
    ) or T2->diag($error // 'no failure recorded');
    T2->like(
        Scalar::Util::blessed($error) ? $error->message : "$error",
        qr/shut down/i,
        'error message names the runtime shutdown',
    );
});

T2->subtest('R1+R21: single observable order barrier -> fail-pending -> queue-free' => sub {
    local $Temporalio::Runtime::SHUTDOWN_DRAIN_TIMEOUT = 0.2;

    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my @order;
    my $barrier_seen = 0;
    my $orig_drain   = \&Temporalio::Core::FFI::queue_drain;
    my $orig_free    = \&Temporalio::Core::FFI::queue_free;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::queue_drain = sub {
        push @order, 'barrier' unless $barrier_seen++;
        return $orig_drain->(@_);
    };
    local *Temporalio::Core::FFI::queue_free =
        sub { push @order, 'queue-free'; $orig_free->(@_) };
    use warnings 'redefine';

    # Callback A: completed but undrained (the barrier must settle it).
    my $user_data_a;
    my $f_a = issue_synthetic($runtime, \$user_data_a);
    $f_a->on_ready(sub { push @order, 'settled-a' });
    my @keep;
    $worker_poll->call(
        $user_data_a, craft_byte_array('payload-a', \@keep), undef);

    # Callback B: never completes (fail_all_pending must settle it).
    my $user_data_b;
    my $f_b = issue_synthetic($runtime, \$user_data_b);
    $f_b->on_fail(sub { push @order, 'fail-pending' });

    $runtime->shutdown;

    T2->is(
        \@order,
        [ 'barrier', 'settled-a', 'fail-pending', 'queue-free' ],
        'shutdown order is barrier -> settle drained -> fail pending -> free',
    );
    T2->ok($f_a->is_done, 'drained callback resolved with its payload');
    T2->ok($f_b->is_failed, 'undeliverable callback failed, not hung');
    # Consume B's failure so Future does not warn about an unreported one.
    my $error_b = $f_b->is_ready ? $f_b->failure : undef;
    T2->ok(
        Scalar::Util::blessed($error_b)
            && $error_b->isa('Temporalio::Exception::Runtime'),
        'pending-callback failure carries the typed shutdown error',
    );
});

T2->done_testing;
