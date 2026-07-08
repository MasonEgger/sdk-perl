# ABOUTME: Spec R4 (finding L12, probe verify-45/pool-payload/probe_pool_globals.pl):
# ABOUTME: activity pool fork-state hand-off must be per-instance, not process-global.
# ABOUTME: Pre-fix, Activity/Pool.pm's ADJUST block published the registry, FD list,
# ABOUTME: and module list into main:: package globals (a bare `class` file compiles
# ABOUTME: file-scope `our` vars into main::), so a second pool's construction
# ABOUTME: clobbered the first pool's state before its lazy children forked: a
# ABOUTME: dispatch through pool A executed pool B's registry.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use IO::Async::Loop ();

use Temporalio::Activity::Invocation ();
use Temporalio::Activity::Pool ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Worker::ActivityRegistry ();

my $loop = IO::Async::Loop->new;

# pool->invoke parks on a REAL fork, so drive it by running the loop;
# $loop->await returns the Future itself (P2.4 lesson), so read the value
# with ->get after it resolves.
sub run_loop ($f, $timeout = 30) {
    $loop->await(Future->wait_any($f, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $f->is_ready;
    return $f->get;
}

my sub registry_returning ($value) {
    return Temporalio::Worker::ActivityRegistry->new(
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'which_pool',
                sync => 1,
                code => sub (@) { return $value },
            ),
        ],
    );
}

my sub invocation ($token) {
    return Temporalio::Activity::Invocation->new(
        activity_type => 'which_pool',
        args          => [],
        info          => { task_token => $token },
        task_token    => $token,
    );
}

# ---------------------------------------------------------------------------
# Two pools with distinct registries in one process. Pool B is constructed
# AFTER pool A but BEFORE pool A's lazy children fork (min_workers => 0 forks
# on first call). Pre-fix, pool B's ADJUST clobbered the shared main::
# registry global, so pool A's child looked 'which_pool' up in pool B's
# registry and returned 'pool-B'. Required behavior (spec R4): each pool's
# children read that pool's own registry, regardless of how many pools exist.
# ---------------------------------------------------------------------------
T2->subtest('R4: dispatch through pool A runs pool A\'s activity' => sub {
    my $pool_a = Temporalio::Activity::Pool->new(
        loop        => $loop,
        max_workers => 1,
        registry    => registry_returning('pool-A'),
    );
    my $pool_b = Temporalio::Activity::Pool->new(
        loop        => $loop,
        max_workers => 1,
        registry    => registry_returning('pool-B'),
    );

    my $result_a = run_loop($pool_a->invoke(invocation('tok-a')));
    T2->is($result_a, 'pool-A',
        "pool A's child runs pool A's registry entry"
            . " (pre-fix: pool B's construction clobbered it)");

    my $result_b = run_loop($pool_b->invoke(invocation('tok-b')));
    T2->is($result_b, 'pool-B', "pool B's child runs pool B's registry entry");

    $pool_a->close;
    $pool_b->close;
});

# ---------------------------------------------------------------------------
# Grep-probe (spec R4 acceptance): no main:: globals remain in Activity/Pool.pm
# for the registry, FD, or module hand-off. In a bare `class` file every
# file-scope `our` declaration lands in main:: (lessons.md), so the probe is:
# no `our` declarations at all in the module source.
# ---------------------------------------------------------------------------
T2->subtest('R4 grep-probe: no main:: globals in Activity/Pool.pm' => sub {
    my $path = $INC{'Temporalio/Activity/Pool.pm'};
    T2->ok(defined $path, 'Activity/Pool.pm located via %INC');

    open my $fh, '<', $path or die "open $path: $!";
    my @our_lines;
    while (my $line = <$fh>) {
        last if $line =~ /^__END__/;    # POD does not compile
        push @our_lines, "$.: $line" if $line =~ /^\s*our\b/;
    }
    close $fh;

    T2->is(\@our_lines, [],
        'no `our` declarations (main:: globals in a bare class file) remain'
            . ' for registry/FD/module hand-off');
});

T2->done_testing;
