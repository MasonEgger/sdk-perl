# ABOUTME: R34 (finding T-flake) acceptance: four dev servers started
# ABOUTME: concurrently, in a repeated loop, come up with no bind failure, on
# ABOUTME: distinct ports, each reachable in its own namespace (no
# ABOUTME: cross-connect). skip_all when the temporal CLI is unavailable.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();
use POSIX ();

use lib "$FindBin::Bin/../lib";
use SubprocessGuard qw(run_guarded);

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor TEMPORAL_CLI first,
# then scan PATH. No download is ever attempted; offline CI must stay green.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Finding T-flake (spec R34): the pre-fix DevServer picked its port with
# Net::EmptyPort (bind :0, read the kernel's pick, FREE it) inside the
# kernel's outbound ephemeral range, and only afterwards did sdk-core's CLI
# try to bind it. Under prove -j4 a neighbor could take the freed port first:
# bind-failure and wrong-server flakes (the known updates.t flake). The fix
# passes port 0 through the bridge so sdk-core picks AND reserves the port and
# reports the bound endpoint back. This file is the acceptance scenario from
# spec R34: the pre-fix failure mode here is probabilistic (a TOCTOU race),
# so the deterministic RED lives in t/unit/emptyport_range.t; this scenario
# maximizes collision pressure so a regression flakes loudly.
#
# Process shape: NOTHING Temporal-flavored loads in THIS process. run_guarded
# forks a guarded child (hard timeout, whole-process-group kill on a hang),
# and that child forks four grandchildren, each of which requires the SDK
# stack AFTER its own fork: forking a process whose sdk-core Tokio threads
# already exist is unsafe (the SubprocessGuard contract).

my $SERVERS    = 4;
my $ITERATIONS = 3;

# Runs in a grandchild: boot one dev server on a UNIQUE namespace, connect to
# the target it reports, and start a workflow in that namespace. A workflow
# start is the cross-connect probe: it fails with namespace-not-found against
# any of the sibling servers, so its success proves the reported target really
# is this grandchild's server. Writes "OK <port>" to $writer on success.
sub start_probe_connect ($idx, $writer) {
    require Future;
    require IO::Async::Loop;
    require Temporalio::Runtime;
    require Temporalio::Test::DevServer;
    require Temporalio::Client;
    require Temporalio::Test::Client;

    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $ns      = "concurrent-$idx-$$";

    my $server = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => $cli,
        namespace     => $ns,
        log_level     => 'warn',
    );
    my ($port) = $server->target =~ /:([0-9]+)\z/
        or die 'unparseable target ' . $server->target . "\n";

    my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
        Temporalio::Client->connect(
            $server->target,
            namespace => $ns,
            runtime   => $runtime,
        );
    });

    my $start = $client->start_workflow(
        'CrossConnectProbe',            # no worker; the run just stays open
        [],
        id         => "probe-$ns",
        task_queue => "probe-$ns",
    );
    $loop->await(Future->wait_any(
        $start->without_cancel, $loop->timeout_future(after => 30)));
    die "cross-connect probe start did not resolve within 30s\n"
        unless $start->is_ready;
    $start->get;    # namespace-not-found here means a cross-connect

    syswrite $writer, "OK $port\n";

    $client->connection->close;
    $server->shutdown;
    $runtime->shutdown;
    return 1;
}

# Runs in the guarded child: fork $SERVERS grandchildren concurrently, reap
# them, and verify every one succeeded on a distinct port.
sub concurrent_servers_once () {
    my (@pids, @readers);
    for my $idx (1 .. $SERVERS) {
        pipe(my $reader, my $writer) or die "pipe: $!";
        my $pid = fork;
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            close $reader;
            my $ok = eval { start_probe_connect($idx, $writer) };
            print STDERR "grandchild $idx died: $@" if $@;
            POSIX::_exit($ok ? 0 : 1);
        }
        close $writer;
        push @pids,    $pid;
        push @readers, $reader;
    }

    my $failures = 0;
    for my $pid (@pids) {
        waitpid($pid, 0);
        $failures++ if $?;
    }
    my @ports;
    for my $reader (@readers) {
        my $line = <$reader> // '';
        push @ports, $1 if $line =~ /^OK ([0-9]+)$/;
        close $reader;
    }

    if ($failures) {
        print STDERR "$failures of $SERVERS grandchildren failed\n";
        return 0;
    }
    if (@ports != $SERVERS) {
        print STDERR 'expected ' . $SERVERS . " OK reports, got: @ports\n";
        return 0;
    }
    my %seen;
    $seen{$_}++ for @ports;
    if (keys %seen != $SERVERS) {
        print STDERR "duplicate ports across concurrent servers: @ports\n";
        return 0;
    }
    return 1;
}

for my $iter (1 .. $ITERATIONS) {
    my %result = run_guarded(\&concurrent_servers_once, timeout => 180);
    T2->ok($result{ok},
        "iteration $iter: $SERVERS concurrent dev servers came up on "
      . 'distinct ports, each reachable in its own namespace')
        or T2->diag($result{reason});
}

T2->done_testing;
