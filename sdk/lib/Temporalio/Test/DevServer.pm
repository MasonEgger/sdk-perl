# ABOUTME: Boots an ephemeral Temporal dev server in-process via the C bridge
# ABOUTME: (spec section 12.2): start/target/shutdown over the callback bridge.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use File::Basename ();
use File::Path ();
use File::Spec ();
use Future ();
use Net::EmptyPort ();
use POSIX ();
use Scalar::Util ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Runtime ();

class Temporalio::Test::DevServer {
    field $runtime          :param;    # Temporalio::Runtime (must outlive us)
    field $handle           :param;    # TemporalCoreEphemeralServer*
    field $target           :param;    # "host:port"
    field $shutdown_timeout :param = 30;
    field $is_shutdown = 0;

    method target ()      { $target }
    method is_shutdown () { $is_shutdown }

    # Await $future on $loop, but never hang: a bridge that fails to call
    # back raises Exception::Runtime instead of wedging the test suite.
    # The caller's future rides inside ->without_cancel: wait_any cancels
    # its losing components (Future 0.52), and a cancelled bridge future
    # could never report the late completion that tells us core released
    # its borrows (finding L3 / spec R3). The shield leaves the caller's
    # future PENDING on the timeout arm, so a settle continuation can still
    # observe the trampoline firing.
    sub _await ($loop, $future, $timeout, $what) {
        $loop->await(Future->wait_any(
            $future->without_cancel,
            $loop->timeout_future(after => $timeout)));
        Temporalio::Exception::Runtime->throw(
            message => "$what did not complete within ${timeout}s")
            unless $future->is_ready;
        return $future->get;    # rethrows Exception::Bridge on failure
    }

    # Suspend IO::Async's process-wide child reaper for a teardown window so
    # sdk-core can reap its own ephemeral-server CLI subprocess (#1). Returns a
    # restore coderef the caller invokes when the window closes.
    #
    # Background: the first time any child process is watched on an
    # IO::Async::Loop (the sync-activity fork pool does this via
    # IO::Async::Function -> watch_process), the loop installs ONE SIGCHLD
    # handler whose _reap_children does waitpid(-1, WNOHANG) and so reaps EVERY
    # exited child, including subprocesses IO::Async never spawned. The loop only
    # detaches that handler through unwatch_process; reaping a child via the
    # SIGCHLD path does not, so the handler LINGERS after the fork pool's
    # children are gone. sdk-core's ephemeral dev server then races it for its
    # own CLI child and loses (issue #1, SEGV / exit 139).
    #
    # We detach that lingering handler for the shutdown window. By the time a
    # DevServer is torn down the worker (and so the fork pool) is already shut
    # down, but IO::Async may still be WATCHING a stopped fork-pool worker that
    # has not been reaped yet (IO::Async::Function->stop is asynchronous). To
    # avoid stranding those as zombies once their reaper is gone, we reap each
    # still-watched pid ourselves (non-blocking) and clear the watch table.
    # After we detach, IO::Async lazily re-installs the handler on its next
    # watch_process (it keys on an unset childwatch_sigid), so no manual re-arm
    # is needed; the restore coderef is a no-op kept for a symmetric call site.
    # The two loop fields (childwatches, childwatch_sigid) are IO::Async::Loop
    # internals; repro_fd_signal.t pins this behavior.
    sub _suspend_io_async_child_reaper ($loop) {
        return sub { } unless Scalar::Util::blessed($loop)
            && $loop->isa('IO::Async::Loop');

        my $sigid = delete $loop->{childwatch_sigid};
        return sub { } unless defined $sigid;

        $loop->detach_signal('CHLD', $sigid);

        # Reap any children IO::Async was still watching (stopped fork-pool
        # workers) so the now-detached reaper does not strand them as zombies,
        # then clear the watch table. Best-effort: a worker still mid-exit will
        # be reaped at process exit instead.
        my $childwatches = delete $loop->{childwatches};
        $loop->{childwatches} = {};
        for my $pid (keys %{ $childwatches // {} }) {
            next if $pid == 0;
            waitpid($pid, POSIX::WNOHANG());
        }

        return sub { };
    }

    # start(%options) — boot a dev server and block until it is serving.
    # All options have working defaults; see POD for the full list.
    sub start ($class, %options) {
        my $runtime  = delete $options{runtime} // Temporalio::Runtime->default;
        my $start_timeout    = delete $options{start_timeout}    // 60;
        my $shutdown_timeout = delete $options{shutdown_timeout} // 30;

        # Server binary: an explicit path (or the TEMPORAL_CLI env override)
        # means ExistingPath; otherwise sdk-core downloads the CLI keyed on
        # sdk_name/sdk_version (download_version 'default').
        my $existing_path = delete $options{existing_path} // $ENV{TEMPORAL_CLI};
        my $sdk_name          = delete $options{sdk_name}          // 'sdk-perl';
        my $sdk_version       = delete $options{sdk_version}
            // do { require Temporalio::SDK; $Temporalio::SDK::VERSION };
        my $download_version  = delete $options{download_version}  // 'default';
        my $download_dest_dir = delete $options{download_dest_dir};
        my $download_ttl      = delete $options{download_ttl_seconds} // 0;

        # Random free port per server (spec section 12.2 / pitfalls item 5)
        # so `prove -j` files never collide.
        my $port      = delete $options{port}      // Net::EmptyPort::empty_port();
        my $namespace = delete $options{namespace} // 'default';
        my $ip        = delete $options{ip}        // '127.0.0.1';
        my $database_filename = delete $options{database_filename};
        my $ui         = delete $options{ui}      ? 1 : 0;
        my $ui_port    = delete $options{ui_port} // 0;
        my $log_format = delete $options{log_format} // 'pretty';
        my $log_level  = delete $options{log_level}  // 'warn';
        my $extra_args = delete $options{extra_args};    # arrayref of CLI args
        my $stderr_file = delete $options{stderr_file}
            // File::Spec->catfile('t', 'tmp', "dev-server.$$.log");

        if (my @unknown = sort keys %options) {
            Temporalio::Exception::Argument->throw(
                message => 'unknown Temporalio::Test::DevServer->start option(s): '
                         . join(', ', @unknown));
        }

        # Build the C option records. @keep pins every backing buffer and
        # nested record until the start completes (testing.rs: options must
        # live through the callback).
        my @keep;
        my sub ref_pair ($name, $value) {
            my ($data, $size) =
                Temporalio::Core::FFI::keep_buffer(\@keep, $value);
            return ("${name}_data" => $data, "${name}_size" => $size);
        }

        my $test_server = Temporalio::Core::FFI::TestServerOptions->new(
            ref_pair(existing_path     => $existing_path),
            ref_pair(sdk_name          => $sdk_name),
            ref_pair(sdk_version       => $sdk_version),
            ref_pair(download_version  => $download_version),
            ref_pair(download_dest_dir => $download_dest_dir),
            port => $port,
            ref_pair(extra_args =>
                (defined $extra_args && @$extra_args)
                    ? join("\n", @$extra_args)
                    : undef),
            download_ttl_seconds => $download_ttl,
        );
        my $dev_options = Temporalio::Core::FFI::DevServerOptions->new(
            test_server => Temporalio::Core::FFI::keep_record(\@keep, $test_server),
            ref_pair(namespace => $namespace),
            ref_pair(ip        => $ip),
            ref_pair(database_filename => $database_filename),
            ui      => $ui,
            ui_port => $ui_port,
            ref_pair(log_format => $log_format),
            ref_pair(log_level  => $log_level),
        );

        # The spawned server inherits our stderr (sdk-core uses
        # Stdio::inherit); point STDERR at the log file for the spawn window
        # so server output is debuggable but never pollutes TAP (spec
        # pitfalls item 5). The child keeps the inherited fd for life.
        my $log_dir = File::Basename::dirname($stderr_file);
        File::Path::make_path($log_dir) unless -d $log_dir;
        open my $saved_stderr, '>&', \*STDERR
            or Temporalio::Exception::Runtime->throw(
                message => "could not save STDERR: $!");
        open STDERR, '>>', $stderr_file
            or Temporalio::Exception::Runtime->throw(
                message => "could not redirect STDERR to $stderr_file: $!");

        my $started = eval {
            my $future = Temporalio::Core::Callback->issue_async(
                $runtime, server_start => sub ($user_data, $trampoline) {
                    Temporalio::Core::FFI::ephemeral_server_start_dev_server(
                        $runtime->core_ptr, $dev_options,
                        $user_data, $trampoline);
                });
            _await($runtime->loop, $future, $start_timeout, 'dev server start');
        };
        my $error = $@;
        open STDERR, '>&', $saved_stderr
            or warn "could not restore STDERR: $!";
        close $saved_stderr;
        die $error if !$started && $error;

        return $class->new(
            runtime          => $runtime,
            handle           => $started->{handle},
            target           => $started->{target},
            shutdown_timeout => $shutdown_timeout,
        );
    }

    # Finding L3 (spec R3): per testing.rs / Core/FFI.pm:625-628, core's
    # shutdown async block borrows the server handle until its callback
    # fires, so the shutdown-timeout arm must NOT free a handle whose bridge
    # future is still pending — the late completion would touch freed memory
    # (the pre-fix code freed unconditionally right after the await). Defer
    # the free to the pending future's settle continuation, with a logged
    # warning. Two settle shapes exist:
    #   - done, or failed with Temporalio::Exception::Bridge: the trampoline
    #     fired (success or fail path), core's borrow is over — free.
    #   - failed with anything else: the runtime's fail_all_pending settled
    #     it at runtime shutdown (spec R21) and no callback ever fired, so
    #     core may still hold the borrow — skip the free and leak the handle
    #     by design (bounded: one dev-server box near process end).
    # If the callback never fires at all, the handle leaks the same way.
    # Related but distinct: R46 (the $is_shutdown flag order) and R33
    # (abandoned futures leaking the CLI subprocess) share this shutdown
    # path and land with the Phase P7 test-helper fixes.
    sub _free_handle_when_settled ($future, $server_handle) {
        warn 'Temporalio::Test::DevServer: shutdown timed out; deferring'
           . " server handle free until the bridge callback settles\n";
        $future->on_ready(sub ($f) {
            if ($f->is_failed) {
                my $error = $f->failure;
                return unless Scalar::Util::blessed($error)
                    && $error->isa('Temporalio::Exception::Bridge');
            }
            Temporalio::Core::FFI::ephemeral_server_free($server_handle);
        });
        return;
    }

    # Idempotent (spec section 12.2). Frees the C server handle only after
    # the shutdown callback fires — the bridge's async block borrows it; on
    # the timeout arm the free is deferred via _free_handle_when_settled.
    #
    # Shutdown-time transport tolerance (P10.0.4): the ephemeral-server shutdown
    # drives RPCs to its own process. If the connection is reset / closed while
    # those are in flight during ordered teardown, the bridge rejects with a
    # transport-shaped Exception::Bridge. The server is going away regardless, so
    # we swallow ONLY teardown-shaped transport errors (same classifier the
    # worker finalize uses) and still free the handle; any other error surfaces.
    method shutdown () {
        return if $is_shutdown;
        $is_shutdown = 1;
        my $future = Temporalio::Core::Callback->issue_async(
            $runtime, server_shutdown => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::ephemeral_server_shutdown(
                    $handle, $user_data, $trampoline);
            });
        # Child-reaper ownership during shutdown (#1). sdk-core's ephemeral
        # server shut down here spawns and waitpid()s its own `temporal` CLI
        # subprocess. If a sync-activity fork pool ran earlier in this process,
        # IO::Async installed a process-wide SIGCHLD reaper whose waitpid(-1)
        # would reap core's CLI child before core's own waitpid, SEGVing core.
        # Suspend that reaper for the shutdown window so core reaps its own
        # child; restore it after.
        my $restore_reaper = _suspend_io_async_child_reaper($runtime->loop);
        my $err;
        {
            local $@;
            eval {
                _await($runtime->loop, $future, $shutdown_timeout,
                       'dev server shutdown');
                1;
            } or $err = $@;
        }
        $restore_reaper->();
        if ($future->is_ready) {
            # done or Bridge-failed: the shutdown callback fired, core's
            # borrow is over (P10.0.4 frees on tolerable transport errors).
            Temporalio::Core::FFI::ephemeral_server_free($handle);
        }
        else {
            # Timeout arm, future still pending: core still borrows the
            # handle (finding L3 / spec R3) — never free it here.
            _free_handle_when_settled($future, $handle);
        }
        $handle = undef;
        if (defined $err) {
            # Loaded lazily on the error path only: the classifier lives in
            # Worker.pm (heavy FFI stack) and a clean shutdown never reaches here.
            require Temporalio::Worker;
            die $err
                unless Temporalio::Worker::_shutdown_error_is_tolerable($err);
        }
        return;
    }

    method DESTROY {
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        return if $is_shutdown;
        # Cannot safely run the event loop from a destructor; the server
        # process leaks until exit. Call ->shutdown explicitly (END block).
        warn 'Temporalio::Test::DevServer: server reclaimed without shutdown;'
           . " call ->shutdown explicitly (target $target)\n";
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Test::DevServer - ephemeral Temporal dev server for tests

=head1 SYNOPSIS

    use Temporalio::Test::DevServer;

    my $server = Temporalio::Test::DevServer->start(
        existing_path => $ENV{TEMPORAL_CLI},    # default; undef = download
        log_level     => 'warn',
    );

    my $target = $server->target;    # "host:port"

    # At end of file (END block or explicit):
    $server->shutdown;

=head1 DESCRIPTION

Boots an ephemeral Temporal dev server in-process via
C<temporal_core_ephemeral_server_start_dev_server> (spec section 12.2),
awaiting the start through the callback bridge. sdk-core spawns the
C<temporal> CLI binary: the C<existing_path> option (defaulting to the
C<TEMPORAL_CLI> environment variable) runs an installed binary; when both
are unset sdk-core downloads and caches one. Each server gets a random
free port via L<Net::EmptyPort> so parallel test files never collide, and
the server's stderr is redirected to C<t/tmp/dev-server.E<lt>pidE<gt>.log>
(override with C<stderr_file>) so failures are debuggable without
polluting TAP.

C<start> blocks until the server is serving (raising
L<Temporalio::Exception::Bridge> on bridge failure, or
L<Temporalio::Exception::Runtime> after C<start_timeout> seconds, default
60) and returns the server object. Remaining options with their defaults:
C<runtime> (the process-default L<Temporalio::Runtime>, which must outlive
the server), C<namespace> ('default'), C<ip> ('127.0.0.1'), C<port>
(random free port), C<database_filename> (in-memory), C<ui> (off),
C<ui_port>, C<log_format> ('pretty'), C<log_level> ('warn'), C<extra_args>
(arrayref of extra CLI args), C<sdk_name>/C<sdk_version>/
C<download_version>/C<download_dest_dir>/C<download_ttl_seconds> (download
behavior when no binary path is given), and C<shutdown_timeout> (30).
Unknown options raise L<Temporalio::Exception::Argument>.

=head1 METHODS

=head2 target

The C<host:port> string the server is listening on.

=head2 shutdown

Stops the server via C<temporal_core_ephemeral_server_shutdown> (awaited
through the callback bridge) and frees the C handle once the shutdown
callback has fired. Idempotent: repeat calls return immediately. If the
shutdown times out while the bridge call is still in flight, the timeout
error is raised but the handle free is deferred until the bridge callback
settles (core still borrows the handle); when the callback never fires,
the handle is deliberately leaked with a logged warning.

=head2 is_shutdown

True once C<shutdown> has run.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Test::DevServer->new(
        runtime => ...,
        handle => ...,
        target => ...,
        shutdown_timeout => ...,
    );

Constructs a Temporalio::Test::DevServer. Named parameters:

=over 4

=item C<runtime>

(required)

=item C<handle>

(required)

=item C<target>

(required)

=item C<shutdown_timeout>

(optional, default C<30>)

=back

=head1 METHODS

=head2 start

Class method (async) that boots a C<temporal server start-dev> instance on a free port and returns a L<Future> resolving to the dev-server handle.

=cut
