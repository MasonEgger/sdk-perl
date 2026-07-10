# ABOUTME: R93 (parity audit client finding 4) acceptance: connect accepts a
# ABOUTME: default_workflow_query_reject_condition applied by query when the
# ABOUTME: per-call reject_condition is omitted (request-captured on the
# ABOUTME: outbound QueryWorkflow); a per-call value overrides the default, and
# ABOUTME: neither leaves the field unset. Python _client.py:144-145,184-187.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Code trace (spec R93 / parity audit client finding 4): pre-fix, connect
# (Client.pm assert_known_keys) rejects default_workflow_query_reject_condition
# outright, and _root_query (Client/WorkflowHandle.pm) reads only the per-call
# $opts{reject_condition} — there is no client-level default at all. Python
# accepts the kwarg on connect (_client.py:144-145), documents it as the
# query-time fallback (:184-187), and applies it as
# `reject_condition or client default` when building the query input
# (_workflow.py:600-601). The guarded scenario pins the Perl equivalent live:
#   * connect(default_workflow_query_reject_condition => 'not_open'), then a
#     query WITHOUT a per-call condition emits an outbound QueryWorkflow
#     carrying the client default (enum 2, request-captured around
#     Client::_rpc_call);
#   * a per-call reject_condition ('none', enum 1) overrides the default;
#   * edge: a client with NO default queried without a per-call value leaves
#     query_reject_condition unset (proto default 0).

# Gate (CLAUDE.md): skip when the temporal CLI is unavailable; offline CI
# stays green.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Modules are LOADED (FFI symbols attached) in the parent, but NOTHING that
# starts sdk-core's Tokio threads runs here — the runtime is created only
# inside the forked child (SubprocessGuard requires this for a safe fork).
require Future;
require IO::Async::Loop;
require Scalar::Util;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require WfDef::QueryGreeter;
require SubprocessGuard;

# temporal.api.enums.v1.QueryRejectCondition (enums/v1/query.proto), verified
# against sdk-python common.py QueryRejectCondition and the R67 map.
use constant {
    QUERY_REJECT_NONE     => 1,
    QUERY_REJECT_NOT_OPEN => 2,
};

my $child = sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $server = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => $cli,
        log_level     => 'warn',
    );

    my $verified = 0;
    my $tw;
    my ($client, $plain_client);
    my $cleanup = sub {
        local $@;
        eval { $tw->shutdown(30) if defined $tw; 1 };
        eval { $client->connection->close if defined $client; 1 };
        eval { $plain_client->connection->close if defined $plain_client; 1 };
        eval { $server->shutdown; 1 };
    };

    my $ok = eval {
        # Client A carries the client-level default under test.
        $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
            Temporalio::Client->connect(
                $server->target,
                namespace => 'default',
                runtime   => $runtime,
                default_workflow_query_reject_condition => 'not_open',
            );
        });

        my $task_queue = 'perl-sdk-r93-' . $$ . '-' . int(rand(1_000_000));
        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => $task_queue,
            workflows  => [qw(WfDef::QueryGreeter)],
        );
        $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

        # QueryGreeter parks its :Run on a long timer, so the workflow stays
        # OPEN and a not_open reject condition never actually rejects — the
        # assertions are about what rides the outbound request.
        my $handle = $tw->start_workflow_with_retry($client,
            'QueryGreeter', [],
            id         => "perl-sdk-r93-$$-" . int(rand(1_000_000)),
            task_queue => $task_queue,
        );
        my $wf_id   = $handle->workflow_id;
        my $the_run = $handle->run_id;

        # Request capture around the one RPC funnel: record every outbound
        # (rpc, request) pair, then delegate to the real call.
        my @calls;
        {
            no warnings 'redefine';
            my $orig = \&Temporalio::Client::_rpc_call;
            *Temporalio::Client::_rpc_call = sub {
                my ($self, $rpc, $request, %opts) = @_;
                push @calls, { rpc => $rpc, request => $request };
                return $orig->($self, $rpc, $request, %opts);
            };
        }
        my $query_captured = sub {
            my @queries = grep { $_->{rpc} eq 'QueryWorkflow' } @calls;
            die "no QueryWorkflow was captured\n" unless @queries;
            # The last one: an idempotent retry re-issues through the funnel.
            return $queries[-1]{request};
        };

        # --- omitted per-call condition rides the client default -----------
        my $r1 = $tw->await_idempotent(sub { $handle->query('greeting') });
        die "query returned '" . ($r1 // 'undef') . "'\n"
            unless ($r1 // '') eq 'initial';
        my $got1 = $query_captured->()->query_reject_condition // 0;
        die "default-riding query carried query_reject_condition $got1"
          . ' (expected ' . QUERY_REJECT_NOT_OPEN . " not_open)\n"
            unless $got1 == QUERY_REJECT_NOT_OPEN;

        # --- a per-call value overrides the client default ------------------
        @calls = ();
        my $r2 = $tw->await_idempotent(sub {
            $handle->query('greeting', [], reject_condition => 'none');
        });
        die "per-call query returned '" . ($r2 // 'undef') . "'\n"
            unless ($r2 // '') eq 'initial';
        my $got2 = $query_captured->()->query_reject_condition // 0;
        die "per-call query carried query_reject_condition $got2"
          . ' (expected ' . QUERY_REJECT_NONE . " none, overriding)\n"
            unless $got2 == QUERY_REJECT_NONE;

        # --- edge: no default and no per-call value leaves it unset ---------
        $plain_client = Temporalio::Test::Client::connect_with_retry($loop, sub {
            Temporalio::Client->connect(
                $server->target,
                namespace => 'default',
                runtime   => $runtime,
            );
        });
        @calls = ();
        my $plain_handle =
            $plain_client->get_workflow_handle($wf_id, run_id => $the_run);
        my $r3 = $tw->await_idempotent(sub { $plain_handle->query('greeting') });
        die "plain-client query returned '" . ($r3 // 'undef') . "'\n"
            unless ($r3 // '') eq 'initial';
        my $got3 = $query_captured->()->query_reject_condition // 0;
        die "plain-client query carried query_reject_condition $got3"
          . " (expected unset / proto default 0)\n"
            unless $got3 == 0;

        $verified = 1;
        1;
    };
    my $scenario_err = $@;

    $cleanup->();
    $runtime->shutdown;

    die $scenario_err if !$ok && $scenario_err;
    return $verified;
};

my %r = SubprocessGuard::run_guarded($child, timeout => 150);
T2->ok($r{ok},
    'connect-level default_workflow_query_reject_condition rides the outbound'
  . ' QueryWorkflow when the per-call condition is omitted, a per-call value'
  . ' overrides it, and neither leaves the field unset (R93)')
    or T2->diag($r{reason});

T2->done_testing;
