# ABOUTME: Spec R18 (finding L13): a heartbeat recorded inside a pooled sync
# ABOUTME: activity must reach the PARENT while the body is still running.
# ABOUTME: Pre-fix, Activity/Pool.pm collected heartbeat frames in the child
# ABOUTME: (the `heartbeat_recorder => sub { push @child_heartbeats, ... }`
# ABOUTME: site) and invoke() relayed them only AFTER the reply arrived (the
# ABOUTME: `for my $hb (@{ $out->{heartbeats} ... })` site), so a long-running
# ABOUTME: body produced no heartbeats at all until it returned and a
# ABOUTME: heartbeat_timeout shorter than the body always fired.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Temp ();
use FindBin ();
use Time::HiRes ();

use lib "$FindBin::Bin/../lib";

use Future ();
use IO::Async::Loop ();

use Temporalio::Activity ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Activity::Invocation ();
use Temporalio::Activity::Pool ();
use Temporalio::Core::Proto ();
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

my $dir       = File::Temp::tempdir(CLEANUP => 1);
my $flag_file = "$dir/unblock";

# The body heartbeats ONCE, then blocks until the parent creates $flag_file
# (deadline-bounded so a pre-fix run cannot hang the suite). The heartbeat
# must be observable in the parent DURING the blocked window.
my $registry = Temporalio::Worker::ActivityRegistry->new(
    activities => [
        Temporalio::Activity::FunctionDefinition->new(
            name => 'hb_then_block',
            sync => 1,
            code => sub ($flag) {
                Temporalio::Activity::heartbeat('ping');
                my $deadline = Time::HiRes::time() + 25;
                until (-e $flag) {
                    return 'gave-up-waiting-for-flag'
                        if Time::HiRes::time() > $deadline;
                    Time::HiRes::sleep(0.05);
                }
                return 'done';
            },
        ),
    ],
);

my @relayed;
my $first_hb = $loop->new_future;
my $pool     = Temporalio::Activity::Pool->new(
    loop            => $loop,
    max_workers     => 1,
    registry        => $registry,
    heartbeat_relay => sub ($token, $bytes) {
        push @relayed, { token => $token, bytes => $bytes };
        $first_hb->done unless $first_hb->is_ready;
        return undef;
    },
);

my $inv = Temporalio::Activity::Invocation->new(
    activity_type => 'hb_then_block',
    args          => [$flag_file],
    info          => { task_token => 'tok-live-hb' },
    task_token    => 'tok-live-hb',
);

# ---------------------------------------------------------------------------
# Spec R18 acceptance: the parent observes the heartbeat BEFORE the body
# returns (bounded relay latency). Pre-fix the relay fires only after the
# reply frame arrives, so the 15s wait below expires with the body still
# blocked and no heartbeat seen (finding L13).
# ---------------------------------------------------------------------------
my $f = $pool->invoke($inv);

$loop->await(Future->wait_any($first_hb->without_cancel,
    $loop->timeout_future(after => 15)));

T2->ok($first_hb->is_ready,
    'parent observed the heartbeat within the relay-latency window'
        . ' (pre-fix: nothing relayed until the body returned, finding L13)');
T2->ok(!$f->is_ready,
    'the body is still running when the heartbeat arrives'
        . ' (live relay, not the post-return batch)');

# Unblock the body and let the invocation finish normally.
open my $fh, '>', $flag_file or die "cannot create $flag_file: $!";
close $fh;
run_to_ready($f);
T2->is($f->get, 'done', 'body completed normally after the unblock');

# The relayed frame is the real serialized coresdk.ActivityHeartbeat for this
# invocation's task token, with the detail payload intact.
T2->ok(scalar(@relayed) >= 1, 'at least one heartbeat frame was relayed');
if (@relayed) {
    T2->is($relayed[0]{token}, 'tok-live-hb',
        'relay received the invocation task token');
    my $HB  = Temporalio::Core::Proto::resolve('coresdk.ActivityHeartbeat');
    my $msg = $HB->decode($relayed[0]{bytes});
    T2->is($msg->task_token, 'tok-live-hb',
        'heartbeat proto carries the task token');
    T2->is(scalar(@{ $msg->details // [] }), 1,
        'heartbeat proto carries the one detail payload');
}

$pool->close;

T2->done_testing;
