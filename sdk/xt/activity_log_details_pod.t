# ABOUTME: Author test (spec R96, parity activity/conversion finding 6):
# ABOUTME: Activity/Context.pm POD documents the log_details field set and
# ABOUTME: the pattern for wiring the details into the caller's own logger.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();

sub slurp ($path) {
    open my $fh, '<:encoding(UTF-8)', $path or die "open $path: $!";
    local $/;
    return readline $fh;
}

my $src = slurp("$FindBin::Bin/../lib/Temporalio/Activity/Context.pm");

# The POD section for the log_details heading: everything up to the next =head.
my ($section) =
    $src =~ /^=head2 log_details$(.*?)(?=^=head[12]\b|\z)/ms;

T2->ok(defined $section, 'Activity/Context.pm has a =head2 log_details section')
    or T2->done_testing, exit;

# Every documented field is named (the Python LoggerAdapter set,
# activity.py:148-159 via 479-537).
for my $field (qw(
    activity_id activity_type attempt namespace task_queue
    workflow_id workflow_run_id workflow_type
)) {
    T2->like($section, qr/C<\Q$field\E>/,
        "log_details POD names the $field field");
}

# The wiring pattern is documented: an example attaching the details to the
# caller's logger (Log::Any is the worked example), and the resolved
# direction that the SDK does not mandate a logging framework.
T2->like($section, qr/Log::Any/,
    'log_details POD shows a Log::Any wiring example');
T2->like($section, qr/log_details/,
    'the wiring example uses the accessor');
T2->like($section, qr/does not (?:mandate|require|depend on)[^.]*logging/is,
    'POD states the SDK does not mandate a logging framework');

T2->done_testing;
