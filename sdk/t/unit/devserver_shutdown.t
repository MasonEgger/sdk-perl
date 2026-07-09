# ABOUTME: DevServer shutdown/start Future-state tests: timeout-arm deferred
# ABOUTME: free (R3/L3), late-start reaper (R33/L26), retryable shutdown (R46/L25).
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

# --- Phase P7 cases (findings L26/L25/T5; spec R33/R46/R47). The Future
# 0.52 loser states behind them are pinned by t/unit/future_semantics.t. ---

T2->subtest('R47: the shutdown timeout diagnostic names the wait and the timeout' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $server  = make_server($runtime, 0.2);

    my $bridge_future;
    no warnings 'redefine';
    local *Temporalio::Core::Callback::issue_async =
        sub ($class, $rt, $kind, $invoke) {
            return $bridge_future = $loop->new_future;
        };
    local *Temporalio::Core::FFI::ephemeral_server_free = sub ($handle) { };
    use warnings 'redefine';
    local $SIG{__WARN__} = sub { };

    my $error = do { local $@; eval { $server->shutdown; 1 } ? undef : $@ };
    # Finding T5 (spec R47): _await must branch on the ACTUAL loser state
    # (the without_cancel shield leaves the bridge future pending on the
    # timeout arm), so the diagnostic names what was awaited and for how
    # long, never the raw Future "was cancelled" message.
    T2->ok(
        Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Runtime')
            && $error->message
                =~ /dev server shutdown did not complete within 0\.2s/,
        'the diagnostic names the awaited operation and the timeout',
    ) or T2->diag($error);

    $bridge_future->done({});    # let the deferred free run
    $runtime->shutdown;
});

T2->subtest('R46: a failed shutdown leaves the server retryable' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $server  = make_server($runtime, 0.2);

    my @issued;
    my @free_calls;
    no warnings 'redefine';
    local *Temporalio::Core::Callback::issue_async =
        sub ($class, $rt, $kind, $invoke) {
            push @issued, $kind;
            # First attempt: the callback fires with a NON-tolerable Bridge
            # failure (a real shutdown bug shape, not the P10.0.4 teardown
            # transport noise). Second attempt: clean success.
            return $loop->new_future->fail(
                Temporalio::Exception::Bridge->new(
                    message => 'shutdown exploded'))
                if @issued == 1;
            return $loop->new_future->done(undef);
        };
    local *Temporalio::Core::FFI::ephemeral_server_free =
        sub ($handle) { push @free_calls, $handle };
    use warnings 'redefine';
    local $SIG{__WARN__} = sub { };

    my $error = do { local $@; eval { $server->shutdown; 1 } ? undef : $@ };
    T2->ok(
        Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Bridge')
            && $error->message =~ /shutdown exploded/,
        'the first shutdown surfaces its real failure',
    ) or T2->diag($error);
    T2->ok(!$server->is_shutdown,
        'is_shutdown stays false after a failed shutdown (finding L25)');
    T2->is(scalar @free_calls, 0,
        'the handle is not freed on the failed attempt (kept for the retry)');

    my $retried = eval { $server->shutdown; 1 };
    T2->ok($retried, 'a second shutdown call still attempts the work and succeeds')
        or T2->diag($@);
    T2->is(\@issued, ['server_shutdown', 'server_shutdown'],
        'the retry re-issued the bridge shutdown');
    T2->is(\@free_calls, [$FAKE_HANDLE],
        'the successful retry frees the handle exactly once');
    T2->ok($server->is_shutdown, 'the flag is set only after success');

    $runtime->shutdown;
});

T2->subtest('R33: a dev server that starts after the timeout is shut down, not leaked' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my ($start_future, $shutdown_future);
    my @issued;
    my @free_calls;
    my @warnings;
    no warnings 'redefine';
    local *Temporalio::Core::Callback::issue_async =
        sub ($class, $rt, $kind, $invoke) {
            push @issued, $kind;
            return $start_future = $loop->new_future
                if $kind eq 'server_start';
            return $shutdown_future = $loop->new_future;
        };
    local *Temporalio::Core::FFI::ephemeral_server_free =
        sub ($handle) { push @free_calls, $handle };
    use warnings 'redefine';
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $error = do {
        local $@;
        eval {
            Temporalio::Test::DevServer->start(
                runtime       => $runtime,
                start_timeout => 0.2,
                existing_path => '/bin/true',
            );
            1;
        } ? undef : $@;
    };
    # R47 sibling assertion: the start diagnostic names the wait + timeout.
    T2->ok(
        Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Runtime')
            && $error->message
                =~ /dev server start did not complete within 0\.2s/,
        'start surfaces the named timeout diagnostic',
    ) or T2->diag($error);
    T2->is(\@issued, ['server_start'], 'only the start was issued so far');
    T2->ok(!$start_future->is_ready,
        'the abandoned start future is still pending (shielded from loser-cancel)');

    # Finding L26 (spec R33): core finally starts the CLI after start()
    # already threw. The reaper must shut the late server down (observe a
    # shutdown call, not a leaked pid) and free its handle once the
    # shutdown callback settles.
    $start_future->done({ handle => $FAKE_HANDLE, target => '127.0.0.1:7233' });
    T2->is(\@issued, ['server_start', 'server_shutdown'],
        'the reaper issues a shutdown for the late-started CLI');
    T2->is(scalar @free_calls, 0,
        'the handle is not freed while the reaper shutdown is in flight');
    T2->like(join('', @warnings), qr/started after the start timeout/,
        'the reap is logged');

    $shutdown_future->done(undef);
    T2->is(\@free_calls, [$FAKE_HANDLE],
        'the late handle is freed once the reaper shutdown settles');

    $runtime->shutdown;
});

T2->done_testing;
