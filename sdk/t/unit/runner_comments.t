# ABOUTME: Documentation guard for the Runner.pm pre-scheduled-cancel comments
# ABOUTME: (spec R51; finding R3, equal to L31b): stale phrasing must stay gone.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();

# Finding R3 (spec R51): the comment on start_nexus_operation's pre-scheduled
# cancel path once claimed it "mirrors the activity/child pre-scheduled-cancel
# behaviour" — a mirror that never existed — and the arm's own code
# contradicted its header comment ("raises Cancelled immediately" while the
# code parked under the wait_* cancellation types). The R8-R10 cluster fixed
# the code; this guard pins the comments to the fixed behavior so the stale
# claims cannot return. Grep-style: assert against the source text, since a
# comment has no runtime behavior to exercise.

my $runner_pm =
    "$FindBin::Bin/../../lib/Temporalio/Workflow/Runner.pm";

open my $fh, '<:encoding(UTF-8)', $runner_pm
    or T2->bail_out("cannot read $runner_pm: $!");
my @lines = <$fh>;
close $fh;
my $source = join '', @lines;

# The contiguous comment block that opens with "Pre-scheduled cancel" inside
# start_nexus_operation (the region the finding targeted).
sub pre_scheduled_block {
    my ($start) = grep { $lines[$_] =~ /^\s*#\s*Pre-scheduled cancel/ }
        0 .. $#lines;
    return undef unless defined $start;
    my $end = $start;
    $end++ while $end < $#lines && $lines[ $end + 1 ] =~ /^\s*#/;
    return join '', @lines[ $start .. $end ];
}

T2->subtest('stale activity/child mirror claim is gone' => sub {
    T2->unlike(
        $source,
        qr/mirrors\s+the\s+activity\/child\s+pre-scheduled-cancel/,
        'the never-built activity/child pre-scheduled-cancel mirror is not claimed',
    );
    T2->unlike(
        $source,
        qr/activity\/child\s+pre-scheduled/,
        'no phrasing implies activities/children have a pre-scheduled-cancel path',
    );
});

T2->subtest('pre-scheduled comment describes the real mechanism' => sub {
    my $block = pre_scheduled_block();
    T2->ok(defined $block, 'found the pre-scheduled-cancel comment block')
        or return;
    T2->like(
        $block,
        qr/_apply_cancel_workflow/,
        'the block names the _apply_cancel_workflow fallback (the actual '
            . 'cancellation-delivery mechanism for the other arms)',
    );
    T2->like(
        $block,
        qr/finding\s+R3\b/,
        'the block cites finding R3, the audit finding this comment answers',
    );
});

T2->done_testing;
