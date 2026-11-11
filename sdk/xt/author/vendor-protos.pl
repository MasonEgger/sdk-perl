#!/usr/bin/env perl
# ABOUTME: Author tool — vendors the complete Temporal proto trees from a local
# ABOUTME: sdk-rust checkout into sdk/share/proto/ (spec section 4.6); run on re-pin.
#
# Usage:
#   git -C /path/to/sdk-rust checkout v0.4.0        # the alien-core pin
#   ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH=/path/to/sdk-rust \
#       perl xt/author/vendor-protos.pl
#
# CHECK THE PIN OUT FIRST. This script copies working-tree files, so whatever
# the checkout is sitting on is the vintage that lands in share/proto, and a
# proto from a later upstream can declare a field the pinned c-bridge's own
# prost types do not know and silently drop (F5, GitHub issue #12: a
# connectivityrule PublicConnectivityRule vendored from HEAD carried an
# enable_stable_ips the 0.4.0 bridge dropped). The pinned tag is $pinned_tag in
# alien-core/alienfile.
#
# The protos crate MOVED after v0.4.0: it is crates/common/protos at the pinned
# tag and crates/protos/protos on a later HEAD, so the root is probed in that
# order rather than hardcoded. Looking only at the HEAD path while standing on
# the tag is what produced the wrong "the tag predates the cloud protos" call
# that F5 undid.
#
# Copies, from <sdk-rust>/<protos root>/:
#   api_upstream/temporal/**        -> share/proto/temporal/   (full api tree)
#   local/temporal/**               -> share/proto/temporal/   (full coresdk tree)
#   api_cloud_upstream/temporal/**  -> share/proto/temporal/   (cloud tree, for
#                                       the raw CloudService client)
#   testsrv_upstream/temporal/**    -> share/proto/temporal/   (testservice tree,
#                                       for the raw TestService client)
#   api_upstream/google/**          -> share/proto/google/     (non-WKT deps only;
#                                       google/protobuf/** is EXCLUDED, because the
#                                       Protobuf distribution bundles the
#                                       well-known types and
#                                       Temporalio::Core::Proto adds its share
#                                       root)
#   google/rpc/**                   -> share/proto/google/rpc/ (google.rpc.Status,
#                                       the gRPC error envelope decoded by the
#                                       spec section 7.5 mapping; lives in its
#                                       own root in sdk-rust, outside
#                                       api_upstream)
#   grpc/health/**                  -> share/proto/grpc/health/ (grpc.health.v1,
#                                       for the raw HealthService client)
#   protoc-gen-openapiv2/**         -> share/proto/protoc-gen-openapiv2/
#                                       (imported by the cloud service protos)
# plus the api_upstream LICENSE for attribution. Only *.proto files are copied.
# The destination tree is wiped first so removals upstream propagate.
#
# One vendored file is NOT under version control upstream:
# temporal/sdk/core/workflow_activation/workflow_activation_fq.proto is
# generated into the checkout's working tree by sdk-rust's build. Run this
# against a built checkout, not a `git archive` extraction, or that file
# disappears. Temporalio::Core::Proto excludes it from parsing either way.
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

# The pinned-tag layout first, the post-tag layout second.
my @candidate_roots = map { File::Spec->catdir($src_root, @$_) }
    [qw(crates common protos)],
    [qw(crates protos protos)];
my ($protos) = grep { -d } @candidate_roots;
$protos or die "proto source root not found; tried:\n"
    . join('', map { "  $_\n" } @candidate_roots);

# Destination: sdk/share/proto, located relative to this script (xt/author/).
my $dest = File::Spec->catdir($FindBin::Bin, File::Spec->updir,
    File::Spec->updir, 'share', 'proto');

# (source subtree, destination subtree, skip-predicate) triples.
my @trees = (
    [ "$protos/api_upstream/temporal", "$dest/temporal", undef ],
    [ "$protos/local/temporal",        "$dest/temporal", undef ],
    # The raw cloud and test service clients (I12/F5). Both upstreams keep
    # their own temporal/api/ subtree, disjoint from api_upstream's, so they
    # merge into the same destination without colliding.
    [ "$protos/api_cloud_upstream/temporal", "$dest/temporal", undef ],
    [ "$protos/testsrv_upstream/temporal",   "$dest/temporal", undef ],
    [ "$protos/api_upstream/google",   "$dest/google",
      # The well-known types ship inside the Protobuf distribution; vendoring
      # a second copy here would shadow the canonical ones (spec section 4.6).
      sub ($rel) { $rel =~ m{^protobuf/} } ],
    # google.rpc.Status (the gRPC error envelope, spec section 7.5) lives in
    # sdk-rust's standalone google/ proto root, not under api_upstream.
    [ "$protos/google/rpc",            "$dest/google/rpc", undef ],
    # grpc.health.v1 (the raw HealthService client) and the openapiv2 options
    # the cloud service protos import: two more standalone roots.
    [ "$protos/grpc",                  "$dest/grpc", undef ],
    [ "$protos/protoc-gen-openapiv2",  "$dest/protoc-gen-openapiv2", undef ],
);

# Validate every source tree BEFORE touching the destination. The probe above
# only proves the protos root exists; a root from an unexpected layout can
# still be missing one subtree, and checking that inside the copy loop below
# would leave share/proto emptied by the wipe and then die partway through.
for my $tree (@trees) {
    -d $tree->[0] or die "expected source tree missing: $tree->[0]\n";
}

# Wipe and recreate so files deleted upstream do not linger.
File::Path::remove_tree($dest) if -d $dest;
File::Path::make_path($dest);

my $copied = 0;
for my $tree (@trees) {
    my ($from, $to, $skip) = @$tree;
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
