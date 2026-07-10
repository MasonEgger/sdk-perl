# ABOUTME: Behavioral tests for the Alien::Temporalio::PerlBridge alienfile and
# ABOUTME: module (T-alien-pb-1..3) building the in-tree Rust callback shim.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Capture::Tiny qw(capture_merged);
use DynaLoader ();
use File::Which qw(which);
use Path::Tiny qw(path);
use Test::Alien::Build;

# Empty import list: Alien::Base->import resolves the installed share dir at
# compile time, which cannot exist for a not-yet-installed Alien under test.
# alien_build_ok provides the runtime properties from the in-test build instead.
use Alien::Temporalio::PerlBridge ();

# Locate the monorepo root (the directory holding the in-tree shim crate) by
# walking up from this test file. Resolves from a plain checkout run
# (alien-perl-bridge/t/) and from inside a dzil .build directory.
my $repo_root = do {
    my $dir = path(__FILE__)->absolute->parent;
    my $found;
    while (!defined $found) {
        $found = $dir
            if $dir->child(qw(ext temporalio-perl-bridge Cargo.toml))->is_file;
        last if $dir->is_rootdir;
        $dir = $dir->parent;
    }
    $found;
};

# Spec section 2.1: the shim is monorepo-shipped code and the build needs
# cargo; without either there is nothing to exercise, so the whole file skips
# (a green suite offline is expected).
T2->skip_all('cargo not found on PATH (install Rust via https://rustup.rs/)')
    unless which('cargo');
T2->skip_all('in-tree ext/temporalio-perl-bridge crate not found (monorepo-only test)')
    unless defined $repo_root;

# The sibling alien-core/lib satisfies the alienfile's Alien::Temporalio::Core
# check during monorepo development (the core Alien need not be installed).
unshift @INC, $repo_root->child(qw(alien-core lib))->stringify
    if $repo_root->child(qw(alien-core lib))->is_dir;

# T-alien-pb-2 runs FIRST, before any successful require of the core Alien can
# populate %INC for the rest of the file.
T2->subtest('T-alien-pb-2: missing Alien::Temporalio::Core dies with install instructions' => sub {
    # Mask the core Alien even if it is loadable in this process: drop any
    # cached entry and prepend an @INC hook that refuses to resolve it.
    delete local $INC{'Alien/Temporalio/Core.pm'};
    local @INC = (sub {
        my (undef, $file) = @_;
        die "Can't locate $file (masked for T-alien-pb-2)\n"
            if $file eq 'Alien/Temporalio/Core.pm';
        return;
    }, @INC);

    my $build = alienfile_ok(filename => 'alienfile');
    T2->ok($build, 'alienfile compiles with the core Alien masked') or return;

    # The prerequisite check must fire in the download stage, which always
    # runs before the build stage where cargo is invoked.
    my ($output, $error) = capture_merged {
        my $ok = eval {
            $build->load_requires('configure');
            $build->load_requires($build->install_type);
            $build->download;
            1;
        };
        $ok ? undef : ($@ || 'unknown failure');
    };
    T2->note($output) if length $output;
    T2->ok(defined $error, 'download stage dies when the core Alien is missing');
    T2->like($error, qr/Alien::Temporalio::Core/, 'diagnostic names the missing prerequisite');
    T2->like($error, qr/cpanm Alien::Temporalio::Core/, 'diagnostic gives install instructions');
});

# T-alien-pb-1 + T-alien-pb-3 share one real build of the in-tree crate.
my $build = alienfile_ok(filename => 'alienfile');
alien_install_type_is 'share', 'probe always selects a share install';
my $alien = alien_build_ok({ class => 'Alien::Temporalio::PerlBridge' });

T2->subtest('T-alien-pb-1: dynamic_libs returns an existing, loadable library' => sub {
    T2->ok($alien, 'alien build succeeded') or return;

    my @libs = $alien->dynamic_libs;
    T2->ok(scalar @libs, 'dynamic_libs returns at least one path') or return;

    my ($lib) = @libs;
    T2->ok(-f $lib, "library file exists: $lib");
    T2->like($lib, qr/temporalio_perl_bridge/, 'library name matches the shim cdylib');

    my $handle = DynaLoader::dl_load_file($lib);
    T2->ok($handle, 'DynaLoader can load the library')
        or T2->diag('dl_error: ' . (DynaLoader::dl_error() // 'unknown'));
});

T2->subtest('T-alien-pb-3: include_dir contains the generated shim header' => sub {
    T2->ok($alien, 'alien build succeeded') or return;

    my $include_dir = $alien->include_dir;
    my $exists = defined $include_dir && -d $include_dir;
    T2->ok($exists, 'include_dir returns an existing directory') or return;
    T2->ok(-f path($include_dir, 'temporalio-perl-bridge.h'),
        "temporalio-perl-bridge.h is installed under $include_dir");
});

T2->done_testing;
