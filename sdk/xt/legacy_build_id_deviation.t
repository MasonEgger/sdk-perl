# ABOUTME: Author test (spec R97, parity client finding 5): Client.pm POD
# ABOUTME: records the deliberate omission of the three deprecated legacy
# ABOUTME: build-id RPCs and points to deployment-based versioning as the
# ABOUTME: supported path, with the raw workflow_service escape hatch noted.
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

my $src = slurp("$FindBin::Bin/../lib/Temporalio/Client.pm");

# The deviation note: everything under its =head1 up to the next =head1.
my ($section) =
    $src =~ /^=head1 OMITTED LEGACY BUILD-ID APIS$(.*?)(?=^=head1\b|\z)/ms;

T2->ok(defined $section,
    'Client.pm has an =head1 OMITTED LEGACY BUILD-ID APIS section')
    or T2->done_testing, exit;

# The three omitted APIs are named (Python client/_client.py:2770,2801,2832,
# all marked ".. deprecated::" there).
for my $api (qw(
    update_worker_build_id_compatibility
    get_worker_build_id_compatibility
    get_worker_task_reachability
)) {
    T2->like($section, qr/C<\Q$api\E>/,
        "deviation note names the omitted $api API");
}

# The note says why (deprecated, superseded) and where to go instead: the
# deployment-based versioning modules Perl already implements.
T2->like($section, qr/deprecated/i,
    'deviation note states the APIs are deprecated in Python');
T2->like($section, qr/L<Temporalio::Worker::DeploymentOptions>/,
    'deviation note links to the DeploymentOptions POD');
T2->like($section, qr/L<Temporalio::Worker::DeploymentVersion>/,
    'deviation note links to the DeploymentVersion POD');
T2->like($section, qr/L<Temporalio::Common::VersioningOverride>/,
    'deviation note links to the VersioningOverride POD');

# The raw escape hatch is noted: the R91 workflow_service handle generates
# its methods from the proto service descriptor, which still carries the
# three legacy rpcs.
T2->like($section, qr/workflow_service/,
    'deviation note points at the raw workflow_service escape hatch');

# Citations: parity audit client finding 5 and the spec section 0
# documented-surface-deviation allowance.
T2->like($section, qr/finding 5/,
    'deviation note cites parity audit client finding 5');
T2->like($section, qr/(?:spec )?section 0|spec .?0/,
    'deviation note cites the spec section 0 deviation allowance');

T2->done_testing;
