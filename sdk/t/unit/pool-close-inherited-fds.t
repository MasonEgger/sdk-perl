# ABOUTME: Spec R30 (finding L16): forked pool children must close every
# ABOUTME: inherited core/client descriptor (the gRPC sockets sdk-core and the
# ABOUTME: client hold open) immediately after fork, keeping only the pool
# ABOUTME: channel fds. Pre-fix the fork setup never enumerated core-owned
# ABOUTME: descriptors: Worker.pm passed only the runtime wakeup handle via
# ABOUTME: inherited_fhs, and the closed-in-child property held ONLY as an
# ABOUTME: emergent side effect of IO::Async's ChildManager fd sweep — a
# ABOUTME: library internal the SDK did not own. The RED failure here is the
# ABOUTME: absent owned sweep (_snapshot_parent_fds/_close_inherited_parent_fds).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

# Linux-specific fd enumeration (spec R30 test notes: acceptable with a skip
# on other platforms).
T2->skip_all('R30 fd audit needs Linux /proc/self/fd')
    unless $^O eq 'linux' && -d '/proc/self/fd';

use FindBin ();
use POSIX ();
use Socket ();
use Storable ();

use lib "$FindBin::Bin/../lib";

use Future ();
use IO::Async::Loop ();

use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Activity::Invocation ();
use Temporalio::Activity::Pool ();
use Temporalio::Worker::ActivityRegistry ();

my $loop = IO::Async::Loop->new;

# pool->invoke parks on a REAL fork; drive it by running the loop (the
# pool-per-instance.t pattern).
sub run_to_ready ($f, $timeout = 30) {
    $loop->await(Future->wait_any($f->without_cancel,
        $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $f->is_ready;
    return $f;
}

# A stand-in for a core/client gRPC socket: a connected AF_UNIX pair the pool
# is told nothing about (finding L16 is precisely that these descriptors are
# never enumerated). Returns the two handles plus their /proc identities.
sub fake_core_sockets () {
    socketpair(my $a, my $b,
        Socket::AF_UNIX(), Socket::SOCK_STREAM(), 0)
        or die "socketpair: $!";
    my %identity = map {
        (fileno($_) => readlink('/proc/self/fd/' . fileno($_)))
    } ($a, $b);
    return ($a, $b, \%identity);
}

# readlink audit of every open descriptor: { fd => identity }.
sub fd_audit () {
    opendir my $dh, '/proc/self/fd' or die "opendir /proc/self/fd: $!";
    my %fds;
    for my $entry (readdir $dh) {
        next unless $entry =~ /^[0-9]+$/;
        my $id = readlink "/proc/self/fd/$entry";
        $fds{$entry} = $id if defined $id;
    }
    closedir $dh;
    return \%fds;
}

# Which of the recorded parent identities survived into $audit as the SAME
# kernel object (fd number AND identity match — a reused number with a new
# inode is not a survivor)?
sub survivors ($identities, $audit) {
    return grep {
        defined $audit->{$_} && $audit->{$_} eq $identities->{$_}
    } sort keys %$identities;
}

# ---------------------------------------------------------------------------
# The owned post-fork sweep (the RED-failing unit, spec R30 root cause: "the
# fork setup never enumerates core-owned descriptors"). A PLAIN fork — no
# IO::Async child setup, so no library fd sweep runs — must be able to close
# every descriptor recorded in the parent snapshot while descriptors created
# AFTER the snapshot (the pool channel fds, by construction) stay open.
# Pre-fix this dies: Temporalio::Activity::Pool has no such routine.
# ---------------------------------------------------------------------------
T2->subtest('owned sweep closes snapshot descriptors, spares the channel' => sub {
    my ($core_a, $core_b, $core_ids) = fake_core_sockets();

    my $snapshot = Temporalio::Activity::Pool::_snapshot_parent_fds();
    T2->ok(ref $snapshot eq 'HASH' && %$snapshot,
        'parent snapshot enumerates open descriptors');
    T2->ok((!grep { $_ <= 2 } keys %$snapshot),
        'stdio is whitelisted out of the snapshot');
    for my $fd (sort keys %$core_ids) {
        T2->is($snapshot->{$fd}, $core_ids->{$fd},
            "snapshot carries the fake core socket on fd $fd");
    }

    # The pool-channel stand-in is created AFTER the snapshot, exactly like
    # the real IO::Async::Function channel and control-connection fds (which
    # come into being at fork-dispatch time, post-refresh).
    socketpair(my $chan_parent, my $chan_child,
        Socket::AF_UNIX(), Socket::SOCK_STREAM(), 0)
        or die "socketpair: $!";

    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {    # child: sweep, audit, report over the channel, _exit
        my $report = eval {
            close $chan_parent;
            Temporalio::Activity::Pool::_close_inherited_parent_fds($snapshot);
            my $audit = fd_audit();
            +{
                audit        => $audit,
                channel_open => (defined $audit->{ fileno $chan_child }
                        ? 1 : 0),
            };
        } // { error => "$@" };
        my $frame = Storable::freeze($report);
        syswrite $chan_child, pack('N', length $frame) . $frame;
        POSIX::_exit(0);
    }

    close $chan_child;
    my $buf = '';
    my $deadline = time + 15;
    while (length($buf) < 4
        || length($buf) < 4 + unpack('N', substr($buf, 0, 4)))
    {
        die "child report did not arrive within 15s\n" if time > $deadline;
        my $n = sysread $chan_parent, my $chunk, 65536;
        die "child closed the channel without a full report\n"
            if defined $n && $n == 0;
        $buf .= $chunk if defined $n;
    }
    waitpid $pid, 0;
    my $report = Storable::thaw(substr($buf, 4));
    T2->ok(!$report->{error}, 'child sweep ran without error')
        or T2->diag($report->{error});

    my @left = survivors($core_ids, $report->{audit} // {});
    T2->ok(!@left,
        'fake core/client sockets are closed in the child after the sweep')
        or T2->diag('survivors: ' . join ', ', @left);
    T2->ok($report->{channel_open},
        'the post-snapshot channel fd survived the sweep in the child');
    # ...and it demonstrably works: the report above arrived over it.
    close $core_a;
    close $core_b;
    close $chan_parent;
});

# ---------------------------------------------------------------------------
# End to end (the spec R30 acceptance criterion): fork a REAL pool child and
# assert via /proc/self/fd that inherited core/client sockets are closed in
# the child while the pool channel fds stay open. One fake pair predates the
# pool, one is opened after construction (pinning the per-invoke snapshot
# refresh: descriptors core opens later must be covered too).
# ---------------------------------------------------------------------------
T2->subtest('pool child closes inherited sockets, keeps its channel' => sub {
    my ($early_a, $early_b, $early_ids) = fake_core_sockets();

    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'fd_audit',
                sync => 1,
                code => \&fd_audit,
            ),
        ],
    );
    my $pool = Temporalio::Activity::Pool->new(
        loop        => $loop,
        max_workers => 1,
        registry    => $registry,
    );

    # Opened AFTER the pool (and its construction-time snapshot) exists.
    my ($late_a, $late_b, $late_ids) = fake_core_sockets();

    my $parent_before = fd_audit();
    my $f             = $pool->invoke(Temporalio::Activity::Invocation->new(
        activity_type => 'fd_audit',
        args          => [],
        info          => { task_token => 'tok-fd-audit' },
        task_token    => 'tok-fd-audit',
    ));
    run_to_ready($f);
    my $child_fds = $f->get;

    my @left = (survivors($early_ids, $child_fds),
        survivors($late_ids, $child_fds));
    T2->ok(!@left,
        'no inherited core/client socket survived into the pool child'
            . ' (early- and late-opened alike)')
        or T2->diag('survivors: ' . join ', ', @left);

    # "The pool channel fds stay open": the audit reply itself round-tripped
    # the IO::Async::Function channel, and the child's freshly connected
    # control socket (a fd the parent never held) is visible in its table.
    my %parent_identity = map { ($_ => 1) } values %$parent_before;
    my @child_only_sockets = grep {
        $child_fds->{$_} =~ /^socket:/ && !$parent_identity{ $child_fds->{$_} }
    } keys %$child_fds;
    T2->ok(scalar(@child_only_sockets) >= 1,
        'the child holds its own control-channel socket (opened post-sweep)');

    $pool->close;
    close $_ for $early_a, $early_b, $late_a, $late_b;
});

T2->done_testing;
