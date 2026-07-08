# ABOUTME: Sync-activity fork pool (spec section 9.4). Runs sync activity
# ABOUTME: bodies in an IO::Async::Function fork pool. The forked children
# ABOUTME: CLOSE inherited parent FDs (the runtime eventfd/pipe + core handles)
# ABOUTME: so a child never drains the parent's completion signal; a per-child
# ABOUTME: control channel streams heartbeats to the parent WHILE the body runs
# ABOUTME: (R18) and delivers post-dispatch cancels down to the child (R19);
# ABOUTME: child errors cross the boundary as encoded Failure protos so their
# ABOUTME: identity survives (R5).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
use feature 'try';
no warnings 'experimental::try';

use Errno ();
use File::Temp ();
use Future ();
use Future::AsyncAwait;
use IO::Async::Function ();
use IO::Async::Handle ();
use IO::Socket::UNIX ();
use POSIX ();
use Scalar::Util ();
use Socket ();
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

    # --- parent-side control-channel state (spec R18+R19) -------------------
    # One UNIX listener per pool; each forked child connects back to it from
    # init_code, giving the pool a per-child duplex stream. $control_dir is
    # the File::Temp dir object holding the socket path (kept alive here so
    # the path is not reaped under a live pool).
    field $control_dir;
    field $control_listener;
    field $listener_handle;     # IO::Async::Handle watching the listener
    field %conns;               # fileno => { fh, handle, buf, token }
    field %token_conn;          # in-flight task token => fileno running it
    field %inflight;            # task tokens with an invoke() in progress
    field %cancel_pending;      # cancels awaiting the child's 'start' frame

    ADJUST {
        # --- the R18/R19 control-channel listener, created BEFORE the fork
        # pool so every child knows the path (it rides the %channel below).
        # IO::Async's child setup closes every parent fd the Routine did not
        # mark "keep" (IO::Async::Internals::ChildManager _spawn_in_child),
        # so a parent-created pipe does NOT survive into the child; a child
        # can, however, connect() a fresh socket to a parent listener from
        # init_code, which runs after that sweep. That per-child connection
        # is the ONE bidirectional side channel both requirements share:
        # heartbeats stream up it while the body runs (R18, finding L13) and
        # post-dispatch cancels flow down it (R19, finding L15).
        $control_dir = File::Temp->newdir('temporalio-pool-XXXXXX',
            TMPDIR => 1);
        my $control_path = "$control_dir/control.sock";
        $control_listener = IO::Socket::UNIX->new(
            Type   => Socket::SOCK_STREAM(),
            Local  => $control_path,
            Listen => 16,
        ) or die 'Temporalio::Activity::Pool: cannot listen on control'
            . " socket $control_path: $!\n";
        $control_listener->blocking(0);

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
        # This %channel is the single fork-state hand-off later steps extend:
        # R5 added structured error data to the reply frame; R18/R19 add
        # `control_path` (and the in-child `child` slot init_code fills) for
        # the live bidirectional side channel — heartbeat up, cancel down.
        my %channel = (
            registry     => $registry,           # in-child activity lookup
            close_fhs    => [@$inherited_fhs],   # FD hygiene: close in init_code
            modules      => [@$activity_modules],# require before first dispatch
            control_path => $control_path,       # R18/R19: child connects here
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
            # inherited parent FDs (FD hygiene), load activity modules, and open
            # the child's end of the control channel.
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
                # R18/R19: connect the per-child control socket. The slot
                # lands in this child's copy of %channel, which the `code`
                # closure below shares, so each child talks over its own
                # connection. A failed connect degrades gracefully: undef
                # control means heartbeats fall back to the reply frame and
                # live cancels are not observed (the pre-R18/R19 behavior).
                $channel{child} = _child_connect_control($channel{control_path});
                return;
            },
            code => sub ($frozen) {
                return _child_dispatch($channel{registry}, $frozen,
                    $channel{child});
            },
        );
        $loop->add($function);

        # Watch the listener: each child's init_code connect lands here. The
        # weak self keeps loop -> handle -> closure -> self from cycling.
        my $weak_self = $self;
        Scalar::Util::weaken($weak_self);
        $listener_handle = IO::Async::Handle->new(
            read_handle   => $control_listener,
            on_read_ready => sub {
                $weak_self->_accept_control if defined $weak_self;
            },
        );
        $loop->add($listener_handle);
    }

    # invoke($invocation, %opts) -> Future resolving to the body's return value
    # (or failing with the body's error). The invocation is frozen to plain
    # data and sent to a child; the child thaws it, runs the body under a
    # reconstructed Context, and returns the (frozen) result. Heartbeats the
    # body records stream to the parent over the control channel WHILE the
    # body runs (R18) and are relayed to the real FFI heartbeat as they
    # arrive; a `cancellation => $token` option wires a parent-side cancel
    # firing mid-body down the same channel (R19).
    async method invoke ($invocation, %opts) {
        my $token = $invocation->task_token;
        $inflight{$token} = 1;

        # Live-cancel wiring (spec R19, finding L15): the pre-R19 channel
        # conveyed cancellation exactly once, as the boolean the dispatcher
        # froze into the invocation; a cancel arriving while the child ran
        # was invisible in-child. Subscribing to the parent-side token here
        # forwards a later cancel down the control channel. (An unlikely
        # cancel BETWEEN the dispatcher's flag capture and this subscription
        # is covered too: is_cancelled is re-checked first.)
        if (defined(my $cancellation = $opts{cancellation})) {
            if ($cancellation->is_cancelled) {
                $self->cancel_invocation($token);
            }
            else {
                my $weak_self = $self;
                Scalar::Util::weaken($weak_self);
                $cancellation->cancelled->on_done(sub {
                    $weak_self->cancel_invocation($token)
                        if defined $weak_self;
                });
            }
        }

        my $frozen = $invocation->freeze;
        my $reply;
        try {
            $reply = await $function->call(args => [ $frozen ]);
        }
        catch ($call_error) {
            delete $inflight{$token};
            delete $cancel_pending{$token};
            die $call_error;
        }
        delete $inflight{$token};
        delete $cancel_pending{$token};

        my $out = Storable::thaw($reply);

        # Degraded-path relay: frames the child could NOT stream live (its
        # control connect failed) come back with the reply and are relayed
        # here, after the body — the pre-R18 behavior, worst case.
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

    # cancel_invocation($task_token): deliver a post-dispatch cancel to the
    # child running $task_token (spec R19). If the child's 'start' frame has
    # not arrived yet — the cancel raced ahead of it — the cancel parks in
    # %cancel_pending and _on_control_frame sends it on arrival. Unknown /
    # already-finished tokens are a no-op.
    method cancel_invocation ($task_token) {
        return unless $inflight{$task_token};
        my $fno  = $token_conn{$task_token};
        my $conn = defined $fno ? $conns{$fno} : undef;
        if (defined $conn) {
            $self->_send_control($conn->{fh},
                { op => 'cancel', token => $task_token });
        }
        else {
            $cancel_pending{$task_token} = 1;
        }
        return;
    }

    method close {
        $function->stop if defined $function;
        # Tear down the control channel: per-connection watches first, then
        # the listener. The tempdir (and socket path) is reaped when
        # $control_dir drops.
        $self->_close_conn($_) for keys %conns;
        if (defined $listener_handle) {
            $loop->remove($listener_handle);
            $listener_handle = undef;
        }
        if (defined $control_listener) {
            close $control_listener;
            $control_listener = undef;
        }
        return;
    }

    # --- parent side of the control channel (spec R18+R19) ------------------

    method _accept_control () {
        while (my $conn_fh = $control_listener->accept) {
            $conn_fh->blocking(0);
            my $fno       = fileno $conn_fh;
            my $weak_self = $self;
            Scalar::Util::weaken($weak_self);
            my $handle = IO::Async::Handle->new(
                read_handle   => $conn_fh,
                on_read_ready => sub {
                    $weak_self->_drain_control($fno) if defined $weak_self;
                },
            );
            $conns{$fno} = {
                fh     => $conn_fh,
                handle => $handle,
                buf    => '',
                token  => undef,
            };
            $loop->add($handle);
        }
        return;
    }

    method _drain_control ($fno) {
        my $conn = $conns{$fno} or return;
        my $eof  = 0;
        while (1) {
            my $n = sysread $conn->{fh}, my $chunk, 65536;
            if (!defined $n) {
                last if $!{EAGAIN} || $!{EWOULDBLOCK};
                $eof = 1;    # hard read error: treat as gone
                last;
            }
            if ($n == 0) { $eof = 1; last; }    # child closed / exited
            $conn->{buf} .= $chunk;
        }
        while (defined(my $msg = _take_frame(\$conn->{buf}))) {
            $self->_on_control_frame($fno, $msg);
        }
        $self->_close_conn($fno) if $eof;
        return;
    }

    # One handler for every frame a child sends up its connection:
    #   start — the child began running a task; note the token->connection
    #           mapping and flush any cancel that raced ahead of it (R19)
    #   hb    — a heartbeat recorded DURING the body; relay it to the real
    #           FFI heartbeat immediately (R18, finding L13 — the pre-R18
    #           pool batched these until the body returned)
    #   end   — the invocation finished; drop the token mapping
    method _on_control_frame ($fno, $msg) {
        my $op    = $msg->{op}    // '';
        my $token = $msg->{token} // '';
        if ($op eq 'start') {
            $conns{$fno}{token} = $token;
            $token_conn{$token} = $fno;
            if (delete $cancel_pending{$token}) {
                $self->_send_control($conns{$fno}{fh},
                    { op => 'cancel', token => $token });
            }
        }
        elsif ($op eq 'hb') {
            $heartbeat_relay->($token, $msg->{bytes})
                if defined $heartbeat_relay;
        }
        elsif ($op eq 'end') {
            delete $token_conn{$token}
                if defined $token_conn{$token} && $token_conn{$token} == $fno;
            $conns{$fno}{token} = undef;
        }
        return;
    }

    method _close_conn ($fno) {
        my $conn = delete $conns{$fno} or return;
        delete $token_conn{ $conn->{token} }
            if defined $conn->{token}
            && defined $token_conn{ $conn->{token} }
            && $token_conn{ $conn->{token} } == $fno;
        $loop->remove($conn->{handle}) if defined $conn->{handle};
        close $conn->{fh}              if defined $conn->{fh};
        return;
    }

    # Parent->child frame write. The connection is non-blocking; frames are
    # tiny (a cancel is well under a hundred bytes), so a full socket buffer
    # is effectively a dead child — bounded retries, then warn and drop.
    method _send_control ($fh, $msg) {
        my $frame    = _pack_frame($msg);
        my $off      = 0;
        my $deadline = time + 5;
        local $SIG{PIPE} = 'IGNORE';
        while ($off < length $frame) {
            my $n = syswrite $fh, $frame, length($frame) - $off, $off;
            if (defined $n) { $off += $n; next; }
            if (($!{EAGAIN} || $!{EWOULDBLOCK}) && time <= $deadline) {
                my $vec = '';
                vec($vec, fileno($fh), 1) = 1;
                select(undef, $vec, undef, 0.05);
                next;
            }
            warn 'Temporalio::Activity::Pool: control-channel write'
                . " failed: $!\n";
            return 0;
        }
        return 1;
    }

    # --- the shared frame codec of the R4 fork-protocol channel -------------
    # Both directions of the R18/R19 side channel speak the same trivial
    # protocol: a 4-byte big-endian length, then a Storable-frozen hashref
    # { op, token, ... }. Package subs so both the parent methods above and
    # the in-child helpers below can call them.
    sub _pack_frame ($msg) {
        my $payload = Storable::freeze($msg);
        return pack('N', length $payload) . $payload;
    }

    sub _take_frame ($bufref) {
        return undef if length($$bufref) < 4;
        my $len = unpack 'N', substr($$bufref, 0, 4);
        return undef if length($$bufref) < 4 + $len;
        my $payload = substr($$bufref, 4, $len);
        substr($$bufref, 0, 4 + $len) = '';
        return Storable::thaw($payload);
    }

    # --- child side ----------------------------------------------------------

    # Runs once per forked child, from init_code, AFTER IO::Async's child
    # setup closed every inherited parent fd (see the ADJUST comment): a
    # freshly connect()ed socket is the only reliable live link back to the
    # parent. Returns the child's control state: { control, buf, cancelled }.
    sub _child_connect_control ($path) {
        my $sock = eval {
            IO::Socket::UNIX->new(
                Type => Socket::SOCK_STREAM(),
                Peer => $path,
            );
        };
        return { control => undef } if !defined $sock;
        $sock->blocking(0);
        return { control => $sock, buf => '', cancelled => {} };
    }

    # Child->parent frame write. Returns true when the frame was fully
    # written; a persistent failure (parent gone) disables the channel so
    # later heartbeats fall back to the collect-and-return path.
    sub _child_send ($child, $msg) {
        my $sock = $child->{control} or return 0;
        my $frame    = _pack_frame($msg);
        my $off      = 0;
        my $deadline = time + 5;
        local $SIG{PIPE} = 'IGNORE';
        while ($off < length $frame) {
            my $n = syswrite $sock, $frame, length($frame) - $off, $off;
            if (defined $n) { $off += $n; next; }
            if (($!{EAGAIN} || $!{EWOULDBLOCK}) && time <= $deadline) {
                my $vec = '';
                vec($vec, fileno($sock), 1) = 1;
                select(undef, $vec, undef, 0.05);
                next;
            }
            $child->{control} = undef;
            return 0;
        }
        return 1;
    }

    # Drain any parent->child frames without blocking, recording cancel
    # tokens. Called from the ChildCancellation poll (every is_cancelled)
    # and from each heartbeat — the natural observation points of a
    # synchronous body (Python parity: a sync activity observes cancellation
    # via its cancelled_event / heartbeat, sdk-python worker/_activity.py).
    sub _child_drain_control ($child) {
        my $sock = $child->{control};
        if (defined $sock) {
            while (1) {
                my $n = sysread $sock, my $chunk, 65536;
                if (!defined $n) {
                    last if $!{EAGAIN} || $!{EWOULDBLOCK};
                    $child->{control} = undef;
                    last;
                }
                if ($n == 0) { $child->{control} = undef; last; }
                $child->{buf} .= $chunk;
            }
        }
        while (defined(my $msg = _take_frame(\$child->{buf}))) {
            $child->{cancelled}{ $msg->{token} } = 1
                if ($msg->{op} // '') eq 'cancel' && defined $msg->{token};
        }
        return;
    }

    # Runs in the forked child once per invocation, with the pool's OWN
    # registry and control state passed in by the per-instance closures (spec
    # R4, finding L12). Defined inside the class block so it is callable as a
    # package sub (a bare-class file otherwise puts file-scope subs in
    # main:: — lessons.md). Returns a frozen { ok, result, heartbeats } or
    # { ok=0, error => STRUCTURED_FRAME, heartbeats }; the error is the
    # _freeze_error carrier (spec R5), not a bare string, so the parent can
    # re-raise the ORIGINAL failure semantics across the fork boundary.
    # `heartbeats` carries only the frames the live channel could NOT stream
    # (control connect failed) — the degraded pre-R18 path.
    sub _child_dispatch ($registry, $frozen, $child) {
        $child //= { control => undef };
        my @child_heartbeats;
        my $token;
        my $out = eval {
            my $inv = Temporalio::Activity::Invocation->thaw($frozen);
            $token = $inv->task_token;

            # Announce the running invocation so the parent can route a
            # post-dispatch cancel to THIS child's connection (R19).
            _child_send($child, { op => 'start', token => $token });

            my $def = defined $registry
                ? $registry->definition($inv->activity_type)
                : undef;
            die "Activity type '" . $inv->activity_type
                . "' is not registered in the activity pool\n"
                if !defined $def;

            # Reconstruct a minimal Context (spec section 9.4 step 3): a
            # fork-safe cancellation seeded from the parent's dispatch-time
            # flag and kept LIVE by polling the control channel (R19,
            # finding L15 — the pre-R19 token was that one-shot boolean),
            # and a heartbeat recorder that STREAMS frames to the parent as
            # the body records them (R18, finding L13 — pre-R18 they were
            # collected and relayed only after the body returned).
            my $cancellation = Temporalio::Activity::ChildCancellation->new(
                cancelled => $inv->is_cancelled,
                poll      => sub {
                    _child_drain_control($child);
                    return ($child->{cancelled}
                            && $child->{cancelled}{$token}) ? 1 : 0;
                },
            );

            my $ctx = Temporalio::Activity::Context->new(
                info               => $inv->info,
                cancellation       => $cancellation,
                # The child has no codec chain; heartbeat() uses the synchronous
                # payload converter only, so a default converter suffices for
                # detail encoding. The parent does all real conversion.
                data_converter     => _pool_data_converter(),
                heartbeat_recorder => sub ($hb_bytes) {
                    if (!_child_send($child,
                        { op => 'hb', token => $token, bytes => $hb_bytes }))
                    {
                        # Live channel unavailable: collect for the parent to
                        # relay after the reply (degraded pre-R18 path).
                        push @child_heartbeats,
                            { token => $token, bytes => $hb_bytes };
                    }
                    # A heartbeat is also a natural cancel-observation point
                    # (Python parity): drain now so the next is_cancelled
                    # sees a cancel that arrived while the body worked.
                    _child_drain_control($child);
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
        if (defined $token) {
            _child_send($child, { op => 'end', token => $token });
            delete $child->{cancelled}{$token} if $child->{cancelled};
        }
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

    # runs in a forked child; a cancel on $cancellation reaches the child live
    my $result = await $pool->invoke($invocation,
        cancellation => $cancellation);
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

=head2 The per-child control channel (spec R18+R19)

Each pool listens on a private UNIX socket; every forked child connects back
to it from C<init_code>, giving the pool one duplex stream per child. (A
parent-created pipe cannot serve here: IO::Async's child setup closes every
inherited fd it did not explicitly keep, so the only reliable live link is a
socket the child opens itself, after that sweep.) Both R18 and R19 ride this
one channel:

=over 4

=item Heartbeat relay (up, R18)

A C<heartbeat()> call inside a forked child cannot touch core. The child's
reconstructed Context streams each serialized C<ActivityHeartbeat> frame up
the control channel B<as the body records it>, and the parent relays it to
C<heartbeat_relay> (the real synchronous FFI heartbeat) immediately — so a
long-running body's heartbeats reach the server while it runs and a
C<heartbeat_timeout> shorter than the body does not fire for a compliant
activity (finding L13: the pre-R18 pool collected frames in the child and
relayed them only after the body returned). If the child's control connect
failed, frames fall back to the collect-and-return path.

=item Cooperative cancellation (down, R19)

A forked child cannot share the parent's core cancellation token. The parent
serializes a C<cancelled> flag into the L<Temporalio::Activity::Invocation>
for a cancel that arrives B<before> dispatch, and C<invoke>'s C<cancellation>
option (or L</cancel_invocation>) forwards a cancel that arrives B<while> the
child runs down the control channel (finding L15: pre-R19, cancellation
crossed the fork exactly once, as that dispatch-time boolean). The child's
L<Temporalio::Activity::ChildCancellation> polls the channel on every
C<is_cancelled> call (and on each heartbeat), so a cooperating body observes
the cancel and its cancellation Future resolves.

=back

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

The registry, FD list, module list, and control-socket path a forked child
reads are captured per pool instance in the closures handed to
L<IO::Async::Function>; fork copies the closure pads, so each pool's children
see that pool's own state. Nothing is published through package globals: two
pools with distinct registries in one process dispatch independently
(finding L12).

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

Shuts the fork pool down, stopping all worker children and tearing down the
control-channel listener and connections.

=head2 invoke

    my $result = await $pool->invoke($invocation, %opts);

Dispatches an activity invocation onto the fork pool, returning a L<Future>
that resolves with the activity result (or fails with the activity error).
The optional C<cancellation> key takes the parent-side
L<Temporalio::Cancellation> for this activity: if it fires while the child
runs, the cancel is delivered down the control channel (spec R19).

=head2 cancel_invocation

    $pool->cancel_invocation($task_token);

Delivers a post-dispatch cancel to the child currently running
C<$task_token> over the control channel. A cancel that races ahead of the
child's start announcement is parked and delivered on arrival; unknown or
already-finished tokens are a no-op.

=cut
