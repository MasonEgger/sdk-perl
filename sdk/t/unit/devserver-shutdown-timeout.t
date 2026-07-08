# ABOUTME: Asserts the DevServer shutdown-timeout arm never frees the C server
# ABOUTME: handle while the bridge future is pending (spec R3; finding L3).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use IO::Async::Loop ();
use Scalar::Util ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Bridge ();
use Temporalio::Exception::Runtime ();
use Temporalio::Runtime ();
use Temporalio::Test::DevServer ();

# Global Requirement 5 guard-assertion tests (the use-after-free window is
# not deterministically executable from a test). Code trace:
#
# - Finding L3 (R3): Test/DevServer.pm:232 freed the server handle via
#   ephemeral_server_free (Core/FFI.pm:625-628,
#   temporal_core_ephemeral_server_free) unconditionally after the shutdown
#   await, including the timeout arm. Per testing.rs the shutdown async
#   block borrows the server box until its callback fires, so the timeout
#   arm freed memory core still borrowed; the late completion then touched
#   the freed box (use-after-free).
# - Compounding it, _await's Future->wait_any CANCELLED the losing bridge
#   future on timeout (Future 0.52 convergent semantics), so the late
#   completion could never even be observed from Perl.
#
# The fix shields the bridge future from wait_any's loser-cancel with
# ->without_cancel, and on the timeout arm defers the free to the still-
# pending future's settle continuation (with a logged warning) instead of
# freeing immediately. A settle that did NOT come from the bridge trampoline
# (the runtime's fail_all_pending shutdown error, typed
# Temporalio::Exception::Runtime rather than Exception::Bridge) skips the
# free and leaks the handle: core may still hold the borrow.
#
# Every subtest spies on ephemeral_server_free WITHOUT forwarding to the
# real FFI function (the synthetic pointer must never reach C) and replaces
# issue_async so no bridge call is ever issued; the returned future is
# test-controlled.

my $FAKE_HANDLE = 0xdead_beef;

# Build a DevServer around a synthetic handle, with issue_async spied to
# return the test-controlled $bridge_future. Returns the server.
sub make_server ($runtime, $shutdown_timeout) {
    return Temporalio::Test::DevServer->new(
        runtime          => $runtime,
        handle           => $FAKE_HANDLE,
        target           => '127.0.0.1:0',
        shutdown_timeout => $shutdown_timeout,
    );
}

T2->subtest('R3: timeout arm defers the free while the bridge future is pending' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $server  = make_server($runtime, 0.2);

    my $bridge_future;
    my @free_calls;
    my @warnings;
    no warnings 'redefine';
    local *Temporalio::Core::Callback::issue_async =
        sub ($class, $rt, $kind, $invoke) {
            T2->is($kind, 'server_shutdown', 'shutdown issues the server_shutdown kind');
            return $bridge_future = $loop->new_future;
        };
    local *Temporalio::Core::FFI::ephemeral_server_free =
        sub ($handle) { push @free_calls, $handle };
    use warnings 'redefine';
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $lived = eval { $server->shutdown; 1 };
    my $error = $@;

    T2->ok(!$lived, 'shutdown still surfaces the timeout error');
    T2->ok(
        Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Runtime')
            && $error->message =~ /did not complete within/,
        'the error is the typed Exception::Runtime timeout',
    ) or T2->diag($error);

    T2->ok(!$bridge_future->is_ready,
        'the bridge future is still PENDING after the timeout arm '
      . '(without_cancel shields it from wait_any loser-cancel)');
    T2->is(scalar @free_calls, 0,
        'ephemeral_server_free is NOT called while the bridge future is pending');
    T2->like(join('', @warnings), qr/deferring server handle free/,
        'the deferral is logged');

    # The late completion: core's trampoline finally fires. Only now may
    # the handle be freed.
    $bridge_future->done({});
    T2->is(\@free_calls, [$FAKE_HANDLE],
        'the deferred free runs exactly once when the bridge future settles');

    $runtime->shutdown;
});

T2->subtest('R3: a late Bridge-typed failure also releases the borrow and frees' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $server  = make_server($runtime, 0.2);

    my $bridge_future;
    my @free_calls;
    no warnings 'redefine';
    local *Temporalio::Core::Callback::issue_async =
        sub ($class, $rt, $kind, $invoke) {
            return $bridge_future = $loop->new_future;
        };
    local *Temporalio::Core::FFI::ephemeral_server_free =
        sub ($handle) { push @free_calls, $handle };
    use warnings 'redefine';
    local $SIG{__WARN__} = sub { };

    eval { $server->shutdown };
    T2->is(scalar @free_calls, 0, 'no free while pending');

    # A Bridge-typed failure comes from the fired fail trampoline: the
    # callback ran, so core's borrow is over and the free is safe.
    $bridge_future->fail(
        Temporalio::Exception::Bridge->new(message => 'transport error'));
    T2->is(\@free_calls, [$FAKE_HANDLE],
        'a Bridge-typed late failure still frees the handle');

    $runtime->shutdown;
});

T2->subtest('R3: a non-Bridge settle (fail_all_pending shape) leaks, never frees' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $server  = make_server($runtime, 0.2);

    my $bridge_future;
    my @free_calls;
    no warnings 'redefine';
    local *Temporalio::Core::Callback::issue_async =
        sub ($class, $rt, $kind, $invoke) {
            return $bridge_future = $loop->new_future;
        };
    local *Temporalio::Core::FFI::ephemeral_server_free =
        sub ($handle) { push @free_calls, $handle };
    use warnings 'redefine';
    local $SIG{__WARN__} = sub { };

    eval { $server->shutdown };

    # Runtime shutdown fails still-pending callback futures with a typed
    # Temporalio::Exception::Runtime (spec R21, fail_all_pending). That
    # settle means the trampoline never fired and core may STILL borrow the
    # handle: the deferred continuation must skip the free (leak by design).
    $bridge_future->fail(
        Temporalio::Exception::Runtime->new(message => 'runtime shut down'));
    T2->is(scalar @free_calls, 0,
        'a non-Bridge failure (no callback ever fired) never frees the handle');

    $runtime->shutdown;
});

T2->subtest('R3 control: a prompt shutdown callback still frees exactly once' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $server  = make_server($runtime, 0.2);

    my @free_calls;
    my @warnings;
    no warnings 'redefine';
    local *Temporalio::Core::Callback::issue_async =
        sub ($class, $rt, $kind, $invoke) {
            return $loop->new_future->done({});
        };
    local *Temporalio::Core::FFI::ephemeral_server_free =
        sub ($handle) { push @free_calls, $handle };
    use warnings 'redefine';
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $lived = eval { $server->shutdown; 1 };
    T2->ok($lived, 'prompt shutdown succeeds') or T2->diag($@);
    T2->is(\@free_calls, [$FAKE_HANDLE],
        'the ready arm frees immediately, exactly once');
    T2->is(scalar @warnings, 0, 'no deferral warning on the prompt path');
    T2->ok($server->is_shutdown, 'server reports shutdown');

    $runtime->shutdown;
});

T2->done_testing;
