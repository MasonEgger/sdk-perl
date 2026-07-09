# ABOUTME: Author test (finding T9 / spec R49): every integration file that
# ABOUTME: binds a dev server at file scope must register teardown in an END
# ABOUTME: block, so a die mid-file still releases the dev-server CLI child.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

# Finding T9 (spec R49): Temporalio::Test::DevServer::DESTROY cannot run the
# event loop (lib/Temporalio/Test/DevServer.pm, DESTROY), so an integration
# file whose explicit ->shutdown is skipped by a die mid-file orphans the
# `temporal` CLI child sdk-core spawned; the orphan inherits the TAP harness
# pipe and wedges a parallel `prove -j4` run. The durable shape: teardown
# registered in an END block. END blocks are compiled before the file body
# runs, so they fire on any runtime die; the lexical guards inside teardown
# make the skip_all path (nothing ever started) a no-op.
#
# Exemption: a file with NO file-scope server binding runs its servers only
# inside SubprocessGuard-forked children (e.g. devserver_concurrent_start.t
# boots its servers in forked grandchildren). A parent END block has no
# handle there, and the children leave via POSIX::_exit so their own END
# blocks never run; the child's eval'd cleanup plus the guard's
# whole-process-group kill own the teardown instead (t/lib/SubprocessGuard.pm).
# Such files must load SubprocessGuard, which is what this probe checks.
#
# Static conventions this probe relies on (matching every current file):
#   - file-scope server bindings are unindented: ^my $var = ...DevServer->start(
#   - END blocks and teardown subs are file-scope: opening line unindented,
#     multi-line bodies closed by a `}` at column 0

my $integration_dir =
    File::Spec->catdir($FindBin::Bin, '..', 't', 'integration');
T2->bail_out("integration dir not found: $integration_dir")
    unless -d $integration_dir;

sub slurp ($path) {
    open my $fh, '<:encoding(UTF-8)', $path or die "open $path: $!";
    local $/;
    return scalar <$fh>;
}

# Extract the block whose opening line matches $re: the matched line itself
# when it already closes (e.g. "END { teardown() }"), otherwise everything up
# to the first column-0 closing brace. A naive scan (no brace counting), which
# is exactly right for the file-scope END/teardown convention above.
sub block_at ($src, $re) {
    return undef unless $src =~ $re;
    my $tail = substr($src, $-[0]);
    my ($first_line) = $tail =~ /\A([^\n]*)/;
    return $first_line if $first_line =~ /\}\s*\z/;
    my ($body) = $tail =~ /\A(.*?^\})/ms;
    return $body // $tail;
}

my @files = sort glob File::Spec->catfile($integration_dir, '*.t');
T2->ok(scalar @files, 'found integration test files');

my $devserver_files = 0;
for my $path (@files) {
    my (undef, undef, $name) = File::Spec->splitpath($path);
    my $src = slurp($path);
    next unless $src =~ /Temporalio::Test::DevServer->start\(/;
    $devserver_files++;

    # Every file-scope server variable this file binds.
    my @scoped_vars =
        $src =~ /^my\s+\$(\w+)\s*=\s*Temporalio::Test::DevServer->start\(/mg;

    if (!@scoped_vars) {
        # No server outlives a file-scope binding: the exemption above. The
        # servers must live in SubprocessGuard-forked children, where the
        # guard (not an END block) owns orphan prevention.
        T2->ok($src =~ /\bSubprocessGuard\b/,
            "$name: no file-scope dev server, so its servers must run under "
          . 'SubprocessGuard (the forked-children exemption)');
        next;
    }

    my $end_body = block_at($src, qr/^END\s*\{/m);
    T2->ok(defined $end_body,
        "$name: registers dev-server teardown in an END block")
        or next;

    # Perl uses $? as the process exit status, and the waitpid calls inside
    # an END-time teardown reset it, silently turning a die's exit 255 into
    # exit 0. TAP's missing plan still fails the file under prove, but
    # direct runs and exit-code-based tooling would be misled: END must
    # localize $? before tearing down.
    T2->ok($end_body =~ /\blocal\s+\$\?;/,
        "$name: END localizes \$? so teardown cannot clobber the exit status");

    # The END body must reach the shutdown: either it shuts down inline, or
    # it calls a file-scope teardown sub that does.
    my $reachable = $end_body;
    if ($end_body !~ /->shutdown\b/ && $end_body =~ /\bteardown\(\)/) {
        $reachable .=
            block_at($src, qr/^(?:my\s+)?sub\s+teardown\b[^\n]*\{/m) // '';
    }
    for my $var (@scoped_vars) {
        T2->ok($reachable =~ /\$\Q$var\E->shutdown\b/,
            "$name: END-reachable teardown shuts down \$$var");
    }
}

T2->ok($devserver_files >= 30,
    "probe scanned the DevServer-using files (saw $devserver_files)");

T2->done_testing;
