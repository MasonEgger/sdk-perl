# ABOUTME: v0.1.0 release version-agreement test (plan P5.5): every Perl
# ABOUTME: distribution and hardcoded $VERSION declares the same dist version.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use File::Spec ();

# The repo root is two levels up from sdk/t/unit/.
my $repo_root = File::Spec->rel2abs(
    File::Spec->catdir($FindBin::Bin, File::Spec->updir, File::Spec->updir,
        File::Spec->updir));

# The single source of truth for the v0.1 milestone (spec section 11:
# "Temporalio::SDK::VERSION = 0.1.0"). All three distributions ship together
# from this monorepo and must agree on the dist version.
my $AGREED_VERSION = '0.1.0';

# --- helpers ---------------------------------------------------------------

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

# Parse the `version = X` line out of a dist.ini (top-level, before any
# [Section]). Dist::Zilla's version assignment lives in the root config block.
sub dist_ini_version {
    my ($rel) = @_;
    my $path = File::Spec->catfile($repo_root, $rel);
    my $content = slurp($path);
    for my $line (split /\n/, $content) {
        next if $line =~ /^\s*;/;          # comment
        if ($line =~ /^\s*version\s*=\s*(\S+)/) {
            return $1;
        }
    }
    return undef;
}

# Extract `our $VERSION = '...';` from a Perl module file.
sub module_version {
    my ($rel) = @_;
    my $path = File::Spec->catfile($repo_root, $rel);
    my $content = slurp($path);
    if ($content =~ /our \s+ \$VERSION \s* = \s* (['"]) (.+?) \1 \s* ;/x) {
        return $2;
    }
    return undef;
}

# Extract the package `version = "..."` from a Cargo.toml [package] table.
sub cargo_version {
    my ($rel) = @_;
    my $path = File::Spec->catfile($repo_root, $rel);
    my $content = slurp($path);
    if ($content =~ /^\s*version\s*=\s*"([^"]+)"/m) {
        return $1;
    }
    return undef;
}

# --- the three distribution dist.ini files ---------------------------------

T2->subtest('dist.ini versions agree' => sub {
    for my $rel (
        'alien-core/dist.ini',
        'alien-perl-bridge/dist.ini',
        'sdk/dist.ini',
    ) {
        T2->is(dist_ini_version($rel), $AGREED_VERSION,
            "$rel declares version $AGREED_VERSION");
    }
});

# --- hardcoded $VERSION declarations in the public modules ------------------

T2->subtest('module $VERSION declarations agree' => sub {
    for my $rel (
        'sdk/lib/Temporalio/SDK.pm',
        'alien-core/lib/Alien/Temporalio/Core.pm',
        'alien-perl-bridge/lib/Alien/Temporalio/PerlBridge.pm',
    ) {
        T2->is(module_version($rel), $AGREED_VERSION,
            "$rel: \$VERSION == $AGREED_VERSION");
    }
});

# --- the Rust shim crate ----------------------------------------------------
# The shim crate is built by alien-perl-bridge and ships as part of the v0.1
# release; its package version participates in the agreement.

T2->subtest('Rust shim crate version agrees' => sub {
    T2->is(cargo_version('ext/temporalio-perl-bridge/Cargo.toml'),
        $AGREED_VERSION,
        "ext/temporalio-perl-bridge/Cargo.toml package version == $AGREED_VERSION");
});

# --- the public SDK $VERSION the spec section 11 acceptance names -----------

T2->subtest('Temporalio::SDK::VERSION == 0.1.0 (spec section 11)' => sub {
    require Temporalio::SDK;
    no warnings 'once';
    T2->is($Temporalio::SDK::VERSION, $AGREED_VERSION,
        '$Temporalio::SDK::VERSION matches the agreed v0.1 release version');
});

# --- the Alien::Temporalio::Core pinned-sdk-core version is a SEPARATE axis --
# Alien convention: ->version reports the UPSTREAM (sdk-core) release, not the
# Perl dist version. That is the pinned sdk-rust tag, and must match the
# alienfile's $pinned_version derivation. This guards against a pin/version
# skew, distinct from the dist-version agreement above.

T2->subtest('alien-core sdk-core pin is internally consistent' => sub {
    my $alienfile = slurp(File::Spec->catfile($repo_root, 'alien-core/alienfile'));
    my ($tag) = $alienfile =~ /\$pinned_tag\s*=\s*'([^']+)'/;
    T2->ok(defined $tag && length $tag, 'alienfile declares a $pinned_tag')
        or return;
    (my $pinned_version = $tag) =~ s/^v//;
    T2->like($pinned_version, qr/^\d+\.\d+\.\d+$/,
        "pinned sdk-core version ($pinned_version) is a semver triple");
    # The pinned sdk-core version is deliberately NOT the Perl dist version:
    # the Alien tracks upstream, the dist tracks our release cadence.
    T2->isnt($pinned_version, $AGREED_VERSION,
        'sdk-core pin is tracked independently of the Perl dist version');
});

T2->done_testing;
