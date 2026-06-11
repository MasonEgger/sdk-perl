# ABOUTME: Behavioral tests for the Alien::Temporalio::Core alienfile and module
# ABOUTME: (T-alien-1, T-alien-3, T-alien-4) using the local sdk-rust override path.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Capture::Tiny qw(capture_merged);
use DynaLoader ();
use File::Which qw(which);
use Test::Alien::Build;

# Empty import list: Alien::Base->import resolves the installed share dir at
# compile time, which cannot exist for a not-yet-installed Alien under test.
# alien_build_ok provides the runtime properties from the in-test build instead.
use Alien::Temporalio::Core ();

# Spec section 2: these tests exercise the ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH
# override path only. Without the override or cargo there is nothing to build,
# so the whole file skips (plan P0.3 note; a green suite offline is expected).

my $sdk_rust_path = $ENV{ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH};
T2->skip_all('set ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH to a local sdk-rust checkout')
    unless defined $sdk_rust_path && length $sdk_rust_path;
T2->skip_all('cargo not found on PATH (install Rust via https://rustup.rs/)')
    unless which('cargo');

T2->subtest('T-alien-3: nonexistent override path dies before invoking cargo' => sub {
    local $ENV{ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH} = '/no/such/sdk-rust-checkout';

    my $build = alienfile_ok(filename => 'alienfile');
    T2->ok($build, 'alienfile compiles with a bogus override path') or return;

    # The existence check must fire in the download stage, which always runs
    # before the build stage where cargo is invoked.
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
    T2->ok(defined $error, 'download stage dies on a nonexistent override path');
    T2->like($error, qr/path does not exist/, 'diagnostic says "path does not exist"');
    T2->like($error, qr{/no/such/sdk-rust-checkout}, 'diagnostic names the offending path');
});

# T-alien-1 + T-alien-4 share one real build against the local checkout.
my $build = alienfile_ok(filename => 'alienfile');
alien_install_type_is 'share', 'probe always selects a share install';
my $alien = alien_build_ok({ class => 'Alien::Temporalio::Core' });

T2->subtest('T-alien-1: dynamic_libs returns an existing, loadable library' => sub {
    T2->ok($alien, 'alien build succeeded') or return;

    my @libs = $alien->dynamic_libs;
    T2->ok(scalar @libs, 'dynamic_libs returns at least one path') or return;

    my ($lib) = @libs;
    T2->ok(-f $lib, "library file exists: $lib");
    T2->like($lib, qr/temporalio_sdk_core_c_bridge/, 'library name matches the c-bridge cdylib');

    my $handle = DynaLoader::dl_load_file($lib);
    T2->ok($handle, 'DynaLoader can load the library')
        or T2->diag('dl_error: ' . (DynaLoader::dl_error() // 'unknown'));
});

T2->subtest('T-alien-4: version returns the pinned sdk-rust tag' => sub {
    T2->ok($alien, 'alien build succeeded') or return;
    T2->is($alien->version, '0.4.0', 'version matches the pinned v0.4.0 tag');
});

T2->done_testing;
