# ABOUTME: R92 (parity audit client finding 2) acceptance: WorkflowHandle gains
# ABOUTME: get_update_handle(update_id, run_id => ..., result_type => ...)
# ABOUTME: returning a WorkflowUpdateHandle bound to the handle's run without any
# ABOUTME: RPC; result() then polls PollWorkflowExecutionUpdate with the given
# ABOUTME: update id and run id (request-captured). Python _workflow.py:978,1008.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Code trace (spec R92 / parity audit client finding 2): pre-fix,
# Client/WorkflowHandle.pm has no get_update_handle even though the backing
# Client/WorkflowUpdateHandle.pm polls purely from workflow_id/run_id/update_id
# through a public constructor — a caller holding a known update id cannot
# rebuild a handle to await it. Python exposes
# WorkflowHandle.get_update_handle(id, workflow_run_id=..., result_type=...)
# (_workflow.py:978) constructing WorkflowUpdateHandle directly with
# `workflow_run_id or self._run_id` (:1001), plus the typed
# get_update_handle_for sugar (:1008). The guarded scenario pins the Perl
# equivalent live:
#   * an update with a known id is driven to completion via start_update;
#   * $handle->get_update_handle($update_id, run_id => $r, result_type => $t)
#     returns a WorkflowUpdateHandle (no RPC at construct) whose result()
#     polls PollWorkflowExecutionUpdate carrying the given update id and run
#     id (request-captured around Client::_rpc_call) and decodes the outcome;
#   * edge: omitting run_id binds the update handle to the handle's OWN run;
#   * the R44 strictness rule holds (unknown option key / missing update id
#     raise the typed Argument error before any RPC).

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
require Temporalio::Exception::Argument;
require WfDef::UpdatableCounter;
require SubprocessGuard;

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
    my $client;
    my $cleanup = sub {
        local $@;
        eval { $tw->shutdown(30) if defined $tw; 1 };
        eval { $client->connection->close if defined $client; 1 };
        eval { $server->shutdown; 1 };
    };

    my $ok = eval {
        $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
            Temporalio::Client->connect(
                $server->target,
                namespace => 'default',
                runtime   => $runtime,
            );
        });

        my $task_queue = 'perl-sdk-r92-' . $$ . '-' . int(rand(1_000_000));
        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => $task_queue,
            workflows  => [qw(WfDef::UpdatableCounter)],
        );
        $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

        my $handle = $tw->start_workflow_with_retry($client,
            'UpdatableCounter', [],
            id         => "perl-sdk-r92-$$-" . int(rand(1_000_000)),
            task_queue => $task_queue,
        );
        my $wf_id   = $handle->workflow_id;
        my $the_run = $handle->run_id;
        die "started handle carries no run_id\n"
            unless defined $the_run && length $the_run;

        # Drive an update with a KNOWN id to completion so a rebuilt handle
        # has a real outcome to poll for.
        my $update_id = "perl-sdk-r92-upd-$$-" . int(rand(1_000_000));
        $tw->await_result($handle->start_update('add', [5],
            wait_for_stage => 'completed', update_id => $update_id), 60);

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
        my $poll_captured = sub {
            my @polls =
                grep { $_->{rpc} eq 'PollWorkflowExecutionUpdate' } @calls;
            die "no PollWorkflowExecutionUpdate was captured\n" unless @polls;
            return $polls[0]{request};
        };

        # --- explicit run_id + result_type ---------------------------------
        my $uh = $handle->get_update_handle($update_id,
            run_id => $the_run, result_type => 'My::Result');
        die 'get_update_handle returned ' . ref($uh) . "\n"
            unless Scalar::Util::blessed($uh)
                && $uh->isa('Temporalio::Client::WorkflowUpdateHandle');
        die "update handle carries update_id '" . $uh->update_id . "'\n"
            unless $uh->update_id eq $update_id;
        die "update handle bound to run '" . ($uh->run_id // '') . "'\n"
            unless ($uh->run_id // '') eq $the_run;
        die "update handle carries workflow_id '" . $uh->workflow_id . "'\n"
            unless $uh->workflow_id eq $wf_id;
        die "result_type not carried on the handle\n"
            unless ($uh->result_type // '') eq 'My::Result';

        my $r = $tw->await_result($uh->result, 30);
        die "rebuilt handle result returned '" . ($r // 'undef') . "'\n"
            unless defined $r && $r == 5;
        my $req = $poll_captured->();
        my $ref = $req->update_ref;
        die "poll carried update_id '" . $ref->update_id . "'\n"
            unless $ref->update_id eq $update_id;
        die "poll carried run_id '"
          . ($ref->workflow_execution->run_id // '') . "'\n"
            unless ($ref->workflow_execution->run_id // '') eq $the_run;
        die "poll carried workflow_id '"
          . $ref->workflow_execution->workflow_id . "'\n"
            unless $ref->workflow_execution->workflow_id eq $wf_id;

        # --- edge: omitted run_id defaults to the handle's own run ---------
        @calls = ();
        my $bound = $client->get_workflow_handle($wf_id, run_id => $the_run);
        my $uh2   = $bound->get_update_handle($update_id);
        die "omitted run_id bound to '" . ($uh2->run_id // '') . "'\n"
            unless ($uh2->run_id // '') eq $the_run;
        my $r2 = $tw->await_result($uh2->result, 30);
        die "defaulted-run handle result returned '" . ($r2 // 'undef') . "'\n"
            unless defined $r2 && $r2 == 5;
        my $req2 = $poll_captured->();
        die "defaulted-run poll carried run_id '"
          . ($req2->update_ref->workflow_execution->run_id // '') . "'\n"
            unless ($req2->update_ref->workflow_execution->run_id // '')
                eq $the_run;

        # --- R44 strictness: typed Argument before any RPC ------------------
        my $typo_err = do {
            local $@;
            eval { $handle->get_update_handle($update_id, bogus => 1); 1 }
                ? undef : $@;
        };
        die "unknown option key did not raise the typed Argument error\n"
            unless Scalar::Util::blessed($typo_err)
                && $typo_err->isa('Temporalio::Exception::Argument');
        my $noid_err = do {
            local $@;
            eval { $handle->get_update_handle(undef); 1 } ? undef : $@;
        };
        die "missing update id did not raise the typed Argument error\n"
            unless Scalar::Util::blessed($noid_err)
                && $noid_err->isa('Temporalio::Exception::Argument');

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
    'get_update_handle rebuilds an update handle bound to the run: result()'
  . ' polls PollWorkflowExecutionUpdate with the given update id and run id,'
  . ' omitted run_id defaults to the handle\'s own run (R92)')
    or T2->diag($r{reason});

T2->done_testing;
