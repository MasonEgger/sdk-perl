# ABOUTME: Integration tests for Temporalio::Test::DevServer (spec section
# ABOUTME: 12.2): start target, distinct ports per process, idempotent shutdown.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor the TEMPORAL_CLI
# env override first, then scan PATH. No download is ever attempted here —
# offline CI must stay green.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Loaded after the gate so machines without the CLI never compile the
# FFI-heavy stack.
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

T2->subtest('start returns an object with a host:port target' => sub {
    T2->isa_ok($server, 'Temporalio::Test::DevServer');
    T2->like($server->target, qr/^\S+:\d+$/, 'target looks like host:port');
    T2->ok(!$server->is_shutdown, 'fresh server reports is_shutdown false');
});

T2->subtest('two servers in one process get distinct ports' => sub {
    my $second = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => $cli,
        log_level     => 'warn',
    );
    T2->like($second->target, qr/^\S+:\d+$/, 'second target looks like host:port');
    T2->isnt($second->target, $server->target, 'targets differ');

    my ($first_port)  = $server->target  =~ /:(\d+)\z/;
    my ($second_port) = $second->target =~ /:(\d+)\z/;
    T2->isnt($second_port, $first_port, 'ports differ');

    my $ok = eval { $second->shutdown; 1 };
    T2->ok($ok, 'second server shuts down') or T2->diag($@);
});

T2->subtest('shutdown is idempotent' => sub {
    my $first = eval { $server->shutdown; 1 };
    T2->ok($first, 'first shutdown lives') or T2->diag($@);
    T2->ok($server->is_shutdown, 'is_shutdown true after shutdown');

    my $second = eval { $server->shutdown; 1 };
    T2->ok($second, 'second shutdown lives (idempotent)') or T2->diag($@);
});

$runtime->shutdown;

T2->done_testing;
