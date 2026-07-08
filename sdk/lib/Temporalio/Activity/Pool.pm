# ABOUTME: Sync-activity fork pool (spec section 9.4). Runs sync activity
# ABOUTME: bodies in an IO::Async::Function fork pool. The forked children
# ABOUTME: CLOSE inherited parent FDs (the runtime eventfd/pipe + core handles)
# ABOUTME: so a child never drains the parent's completion signal; heartbeats
# ABOUTME: called inside a child relay back to the parent, which performs the
# ABOUTME: real FFI heartbeat; cooperative cancellation propagates parent->child
# ABOUTME: through the serialized invocation struct; child errors cross the
# ABOUTME: boundary as encoded Failure protos so their identity survives (R5).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;
use IO::Async::Function ();
use POSIX ();
use Storable ();

use Temporalio::Activity ();
use Temporalio::Activity::ChildCancellation ();
use Temporalio::Activity::Context ();
use Temporalio::Activity::Invocation ();

class Temporalio::Activity::Pool {
    field $loop :param;
    field $max_workers :param = 4;

    # The Temporalio::Worker::ActivityRegistry: the child looks the sync body
    # up by activity type. The registry's code refs are fork-copied into each
    # child interpreter.
    field $registry :param = undef;

    # Filehandles the forked child MUST close before running any body (spec
    # section 9.4): the runtime eventfd/pipe and any open core/client handles.
    # Closing them is the central correctness property — a child holding the
    # parent's signal fd corrupts the completion drain. These are passed as
    # FILEHANDLES (not bare fd numbers): IO::Async::Function renumbers fds in
    # the child, so the kernel object must be closed via the handle the fork
    # copied, not by an fd number that may already be reused.
    field $inherited_fhs :param = [];

    # Module names the child requires before dispatch (so activity classes are
    # present in the child interpreter). Defaults to empty — fork-copied code
    # refs already carry the body for FunctionDefinition activities.
    field $activity_modules :param = [];

    # A coderef ($task_token, $heartbeat_bytes) -> $error_or_undef invoked on
    # the PARENT side for each heartbeat a child relays. The worker supplies one
    # that performs the synchronous FFI worker_record_activity_heartbeat. undef
    # => heartbeats from children are dropped (no relay wired).
    field $heartbeat_relay :param = undef;

    field $function;

    ADJUST {
        # --- the per-instance fork channel (spec R4, finding L12) -----------
        # Everything a forked child needs from THIS pool is captured here, in
        # lexicals closed over by the `init_code`/`code` closures below. fork
        # copies the closure pads, so each pool's children read that pool's
        # own registry, FD list, and module list no matter how many pools
        # exist in the process. (The pre-R4 design published these through
        # file-scope `our` vars, which a bare `class` file compiles into
        # main:: (lessons.md); a second pool's ADJUST clobbered the first
        # pool's state before its lazy children forked, so pool A dispatched
        # through pool B's registry.)
        #
        # This %channel is the single fork-state hand-off that later steps
        # extend: R5 adds structured error data to the reply frame, R18/R19
        # add the bidirectional side channel (live heartbeat up, live cancel
        # down) alongside it.
        my %channel = (
            registry  => $registry,           # in-child activity lookup
            close_fhs => [@$inherited_fhs],   # FD hygiene: close in init_code
            modules   => [@$activity_modules],# require before first dispatch
        );

        # Reaper-ownership note (#1): the first time this fork pool forks a
        # worker, IO::Async installs ONE process-wide SIGCHLD handler whose
        # waitpid(-1) reaps EVERY exited child, and it lingers after the pool's
        # children are gone (the loop only detaches it via unwatch_process).
        # That reaper would race sdk-core's ephemeral dev-server CLI subprocess
        # at teardown; Temporalio::Test::DevServer->shutdown suspends it for the
        # core-shutdown window so core reaps its own child. See that method.
        $function = IO::Async::Function->new(
            min_workers => 0,
            max_workers => $max_workers,
            # init_code runs ONCE per forked child, before any invocation: close
            # inherited parent FDs (FD hygiene) and load activity modules.
            init_code => sub {
                # Close inherited parent handles by the FILEHANDLE the fork
                # copied (close($fh) closes the right kernel fd regardless of
                # any fd-number renumbering IO::Async::Function did in the
                # child). A bare POSIX::close on a stale fd number would either
                # error or, worse, close one of the function's own channel fds.
                for my $fh (@{ $channel{close_fhs} }) {
                    close($fh) if defined $fh;
                }
                for my $mod (@{ $channel{modules} }) {
                    my $path = ($mod =~ s{::}{/}gr) . '.pm';
                    eval { require $path; 1 };
                }
                return;
            },
            code => sub ($frozen) {
                return _child_dispatch($channel{registry}, $frozen);
            },
        );
        $loop->add($function);
    }

    # invoke($invocation) -> Future resolving to the body's return value (or
    # failing with the body's error). The invocation is frozen to plain data and
    # sent to a child; the child thaws it, runs the body under a reconstructed
    # Context, and returns the (frozen) result plus any heartbeat frames the
    # body produced. The parent then relays each heartbeat to the real FFI call.
    async method invoke ($invocation) {
        my $frozen = $invocation->freeze;
        my $reply  = await $function->call(args => [ $frozen ]);
        my $out    = Storable::thaw($reply);

        # Relay each heartbeat the child collected to the real (parent-side)
        # FFI heartbeat call.
        if (defined $heartbeat_relay) {
            for my $hb (@{ $out->{heartbeats} // [] }) {
                $heartbeat_relay->($hb->{token}, $hb->{bytes});
            }
        }

        if ($out->{ok}) {
            return $out->{result};
        }
        # The child ships its error in the structured frame _freeze_error
        # built; rebuild the blessed exception with the original failure
        # semantics before rethrowing (spec R5, finding L14).
        die _thaw_error($out->{error});
    }

    method close {
        $function->stop if defined $function;
        return;
    }

    # --- child side --------------------------------------------------------

    # Runs in the forked child once per invocation, with the pool's OWN
    # registry passed in by the per-instance `code` closure (spec R4, finding
    # L12). Defined inside the class block so it is callable as a package sub
    # (a bare-class file otherwise puts file-scope subs in main:: —
    # lessons.md). Returns a frozen { ok, result, heartbeats } or
    # { ok=0, error => STRUCTURED_FRAME, heartbeats }; the error is the
    # _freeze_error carrier (spec R5), not a bare string, so the parent can
    # re-raise the ORIGINAL failure semantics across the fork boundary and
    # relay heartbeats.
    sub _child_dispatch ($registry, $frozen) {
        # Per-invocation in-child heartbeat collector. A child cannot touch
        # the parent's core, and IO::Async::Function renumbers/closes spare
        # fds in the worker, so a live pipe back to the parent is not
        # reliable. Instead the child COLLECTS its heartbeat frames during
        # the body; they return with the result and the PARENT relays each to
        # the real FFI heartbeat (spec section 9.4 — the parent performs the
        # actual heartbeat call).
        my @child_heartbeats;
        my $out = eval {
            my $inv = Temporalio::Activity::Invocation->thaw($frozen);

            my $def = defined $registry
                ? $registry->definition($inv->activity_type)
                : undef;
            die "Activity type '" . $inv->activity_type
                . "' is not registered in the activity pool\n"
                if !defined $def;

            # Reconstruct a minimal Context (spec section 9.4 step 3): a
            # fork-safe cancellation reflecting the parent's flag, and a
            # heartbeat recorder that COLLECTS frames for the parent to relay
            # (the child must never touch core directly).
            my $cancellation = Temporalio::Activity::ChildCancellation->new(
                cancelled => $inv->is_cancelled);

            my $token = $inv->task_token;
            my $ctx = Temporalio::Activity::Context->new(
                info               => $inv->info,
                cancellation       => $cancellation,
                # The child has no codec chain; heartbeat() uses the synchronous
                # payload converter only, so a default converter suffices for
                # detail encoding. The parent does all real conversion.
                data_converter     => _pool_data_converter(),
                heartbeat_recorder => sub ($hb_bytes) {
                    push @child_heartbeats, { token => $token, bytes => $hb_bytes };
                    return undef;
                },
            );

            my $result = do {
                no warnings 'once';
                local $Temporalio::Activity::Context::CURRENT = $ctx;
                $def->{code}->(@{ $inv->args });
            };
            +{ ok => 1, result => $result };
        };
        my %frame;
        if (!defined $out) {
            %frame = ( ok => 0, error => _freeze_error($@) );
        }
        else {
            %frame = %$out;
        }
        $frame{heartbeats} = [ @child_heartbeats ];
        return Storable::freeze(\%frame);
    }

    # --- the structured-error leg of the R4 fork channel (spec R5) ----------
    # _freeze_error (child) and _thaw_error (parent) are the ONE encode/decode
    # pair for errors crossing the fork boundary. Finding L14: the pre-R5
    # channel stringified the child's $@ and the dispatcher's _as_exception
    # rewrapped the string as a generic RETRYABLE ApplicationError, so a
    # non-retryable failure retried forever. `feature 'class'` exception
    # objects cannot cross Storable, so the carrier is the failure-converter
    # shape: the child converts the exception into a
    # temporal.api.failure.v1.Failure proto (class -> failure_info variant
    # plus type, non_retryable, details, category, and the cause chain) and
    # ships its encoded bytes; the parent decodes the bytes and rebuilds the
    # equivalent blessed exception. Python parity: sdk-python's process-pool
    # executor pickles the ORIGINAL exception back to the parent, so the
    # parent-side encode_failure sees the original identity
    # (temporalio/worker/_activity.py); this pair is the Perl analog for
    # objects pickle-equivalent serialization cannot carry.
    sub _freeze_error ($error) {
        my $string = "$error";
        chomp $string;
        my $bytes = eval {
            my $dc = _pool_data_converter();
            $dc->failure_converter
                ->to_failure($error, $dc->payload_converter)->encode;
        };
        # An error the converter cannot carry (e.g. details the default
        # payload converter cannot encode) degrades to the stringified form;
        # the parent then rethrows the string and the dispatcher wraps it as
        # a generic retryable failure (the pre-R5 behavior, worst case).
        return defined $bytes
            ? { failure => $bytes, string => $string }
            : { string => $string };
    }

    sub _thaw_error ($frame) {
        # A pre-structured (plain string) frame rethrows as-is.
        return $frame if !ref $frame;
        if (defined(my $bytes = $frame->{failure})) {
            my $exception = eval {
                require Temporalio::Core::Proto;
                my $failure = Temporalio::Core::Proto::resolve(
                    'temporal.api.failure.v1.Failure')->decode($bytes);
                my $dc = _pool_data_converter();
                $dc->failure_converter
                    ->from_failure($failure, $dc->payload_converter);
            };
            return $exception if defined $exception;
        }
        return ($frame->{string} // 'activity pool child failed') . "\n";
    }

    # A default data converter used symmetrically on BOTH sides of the fork
    # boundary: the child's Context heartbeat detail encoding and the child
    # half of _freeze_error, and the parent half of _thaw_error (decode must
    # mirror the child's encode, so both sides use the same default; the
    # worker's real converter, which may carry a codec chain, re-encodes the
    # rebuilt exception later at the completion boundary). Required lazily so
    # the child does not load it unless heartbeats or errors occur. Defined
    # inside the class block (callable in-child).
    sub _pool_data_converter {
        require Temporalio::Converter::Data;
        return Temporalio::Converter::Data->new;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Activity::Pool - sync-activity fork pool

=head1 SYNOPSIS

    my $pool = Temporalio::Activity::Pool->new(
        loop            => $io_async_loop,
        max_workers     => 4,
        registry        => $activity_registry,
        inherited_fhs   => [ $runtime_eventfd_handle, ... ],
        heartbeat_relay => sub ($task_token, $hb_bytes) {
            # parent: perform the FFI worker_record_activity_heartbeat
            return $err_or_undef;
        },
    );

    my $result = await $pool->invoke($invocation);   # runs in a forked child
    $pool->close;

=head1 DESCRIPTION

The sync-activity executor of spec section 9.4. Sync activities run in an
L<IO::Async::Function> fork pool rather than on the main event loop, so a
blocking body cannot stall the worker's poll/completion loops.

=head2 FD hygiene (the central correctness property)

Each forked child runs C<init_code> exactly once before its first body, which
C<close>s every inherited handle in C<inherited_fhs> — the runtime eventfd/pipe
and any open core or client handles. A child that kept the parent's completion
signal fd would corrupt the parent's completion drain. The handles are closed
B<by filehandle>, not fd number, because L<IO::Async::Function> renumbers fds
in the child. T-act-10 verifies the parent's eventfd kernel object is gone from
the child.

=head2 Heartbeat relay

A C<heartbeat()> call inside a forked child cannot touch core. The child's
reconstructed Context collects each serialized C<ActivityHeartbeat> frame;
C<_child_dispatch> returns the frames with the result, and the parent's
C<invoke> relays each to C<heartbeat_relay>, which performs the real
synchronous FFI heartbeat. (A live cross-fork pipe is not used: the worker
process renumbers and closes spare fds, so a parent-side pipe fd is not
reliably reachable from the child.)

=head2 Cooperative cancellation

A forked child cannot share the parent's core cancellation token. The parent
serializes a C<cancelled> flag into the L<Temporalio::Activity::Invocation>;
the child reconstructs a L<Temporalio::Activity::ChildCancellation> reflecting
it, so the body's C<< $ctx->cancellation->is_cancelled >> is honored.

=head2 Cross-fork invocation struct

The only thing sent to a child is a frozen
L<Temporalio::Activity::Invocation> — plain data with the activity type,
B<already-converted> args, the info hashref, the task token, and the cancelled
flag. No live core pointers, cancellation tokens, or data converters cross the
fork boundary.

=head2 Error identity across the fork (spec R5)

A child body's thrown error crosses the boundary as an encoded
C<temporal.api.failure.v1.Failure> proto (the failure-converter shape), not a
stringified C<$@>: the child converts the exception via
L<Temporalio::Converter::Failure> and the parent rebuilds the equivalent
blessed L<Temporalio::Exception> before C<invoke> rethrows it. A non-retryable
L<Temporalio::Exception::Application> therefore stays non-retryable, with its
type, details, category, and cause chain intact (finding L14); a plain die
arrives as a retryable ApplicationError with the message preserved. An error
the default converter cannot carry degrades to the stringified form.

=head2 Per-instance fork state (spec R4)

The registry, FD list, and module list a forked child reads are captured
per pool instance in the closures handed to L<IO::Async::Function>; fork
copies the closure pads, so each pool's children see that pool's own state.
Nothing is published through package globals: two pools with distinct
registries in one process dispatch independently (finding L12).

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Activity::Pool->new(
        loop => ...,
        max_workers => ...,
        registry => ...,
        inherited_fhs => ...,
        activity_modules => ...,
        heartbeat_relay => ...,
    );

Constructs a Temporalio::Activity::Pool. Named parameters:

=over 4

=item C<loop>

(required)

=item C<max_workers>

(optional, default C<4>)

=item C<registry>

(optional, default C<undef>)

=item C<inherited_fhs>

(optional, default C<[]>)

=item C<activity_modules>

(optional, default C<[]>)

=item C<heartbeat_relay>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 close

Shuts the fork pool down, stopping all worker children.

=head2 invoke

Dispatches an activity invocation onto the fork pool, returning a L<Future> that resolves with the activity result (or fails with the activity error).

=cut
