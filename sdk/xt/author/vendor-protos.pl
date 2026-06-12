#!/usr/bin/env perl
# ABOUTME: Author tool — vendors the complete Temporal proto trees from a local
# ABOUTME: sdk-rust checkout into sdk/share/proto/ (spec section 4.6); run on re-pin.
#
# Usage:
#   ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH=/path/to/sdk-rust \
#       perl xt/author/vendor-protos.pl
#
# Copies, from <sdk-rust>/crates/protos/protos/:
#   api_upstream/temporal/**   -> share/proto/temporal/        (full api tree)
#   local/temporal/**          -> share/proto/temporal/        (full coresdk tree)
#   api_upstream/google/**     -> share/proto/google/          (non-WKT deps only;
#                                  google/protobuf/** is EXCLUDED — the Protobuf
#                                  distribution bundles the well-known types and
#                                  Temporalio::Core::Proto adds its share root)
# plus the api_upstream LICENSE for attribution. Only *.proto files are copied.
# The destination tree is wiped first so removals upstream propagate.
use v5.38;
use warnings;

use File::Basename ();
use File::Copy ();
use File::Find ();
use File::Path ();
use File::Spec ();
use FindBin ();

my $src_root = $ENV{ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH}
    // die "ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH is not set; point it at an\n"
         . "sdk-rust checkout at the pinned tag (see alien-core/alienfile).\n";

my $protos = File::Spec->catdir($src_root, 'crates', 'protos', 'protos');
-d $protos or die "proto source root not found: $protos\n";

# Destination: sdk/share/proto, located relative to this script (xt/author/).
my $dest = File::Spec->catdir($FindBin::Bin, File::Spec->updir,
    File::Spec->updir, 'share', 'proto');

# Wipe and recreate so files deleted upstream do not linger.
File::Path::remove_tree($dest) if -d $dest;
File::Path::make_path($dest);

# (source subtree, destination subtree, skip-predicate) triples.
my @trees = (
    [ "$protos/api_upstream/temporal", "$dest/temporal", undef ],
    [ "$protos/local/temporal",        "$dest/temporal", undef ],
    [ "$protos/api_upstream/google",   "$dest/google",
      # The well-known types ship inside the Protobuf distribution; vendoring
      # a second copy here would shadow the canonical ones (spec section 4.6).
      sub ($rel) { $rel =~ m{^protobuf/} } ],
);

my $copied = 0;
for my $tree (@trees) {
    my ($from, $to, $skip) = @$tree;
    -d $from or die "expected source tree missing: $from\n";
    File::Find::find({
        no_chdir => 1,
        wanted   => sub {
            return unless -f $File::Find::name && /\.proto\z/;
            my $rel = File::Spec->abs2rel($File::Find::name, $from);
            return if $skip && $skip->($rel);
            my $target = File::Spec->catfile($to, $rel);
            File::Path::make_path(File::Basename::dirname($target));
            File::Copy::copy($File::Find::name, $target)
                or die "copy $File::Find::name -> $target: $!\n";
            $copied++;
        },
    }, $from);
}

# Attribution for the vendored api_upstream tree.
my $license = File::Spec->catfile($protos, 'api_upstream', 'LICENSE');
if (-f $license) {
    File::Copy::copy($license, File::Spec->catfile($dest, 'LICENSE-api'))
        or die "copy LICENSE: $!\n";
}

say "vendored $copied .proto files into $dest";
