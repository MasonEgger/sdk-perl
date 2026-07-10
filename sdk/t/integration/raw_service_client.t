# ABOUTME: R91 (parity audit client finding 1) acceptance: the client exposes
# ABOUTME: raw workflow_service/operator_service handles over the c-bridge
# ABOUTME: rpc-call surface, so operator-namespace RPCs (search-attribute
# ABOUTME: management) and raw workflow-service calls are reachable. Python
# ABOUTME: parity _client.py:307-322 / service.py generated service classes.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";
use SubprocessGuard qw(run_guarded);

# Code trace (spec R91 / parity audit client finding 1): pre-fix, grep for
# operator_service/workflow_service in sdk/lib returns nothing: the high-level
# client is the ONLY RPC surface, and operator-service RPCs are unreachable
# even though the c-bridge dispatches them (client.rs call_operator_service,
# service discriminator Operator=2 already in Client.pm %RPC_SERVICE). Python
# exposes client.workflow_service / client.operator_service (_client.py:307-322)
# as generated per-RPC passthrough classes over the service client's _rpc_call
# (bridge/services_generated.py). The scenario here pins the Perl equivalents
# against a live dev server:
#   * $client->workflow_service: a raw GetSystemInfo round-trips through the
#     handle (request formed, sent, and the typed response decoded);
#   * $client->operator_service: AddSearchAttributes registers a custom search
#     attribute, ListSearchAttributes shows it (proof the add was formed and
#     sent: the list reads the server's own state back), and
#     RemoveSearchAttributes deletes it again.
#
# Process shape: nothing Temporal-flavored loads in THIS process (the
# SubprocessGuard contract); the guarded child requires the SDK stack after
# its own fork.

# Gate (CLAUDE.md): skip when the temporal CLI is unavailable; offline CI
# stays green.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}

T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

my %live = run_guarded(sub {
    require Future;
    require IO::Async::Loop;
    require Temporalio::Runtime;
    require Temporalio::Test::DevServer;
    require Temporalio::Client;
    require Temporalio::Core::Proto;

    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $server  = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => $cli,
        log_level     => 'warn',
    );

    # Everything after the server start runs under an eval so a failing
    # scenario still shuts the server down (an orphaned dev-server CLI
    # inherits this child's stdout, prove's TAP pipe, and wedges prove;
    # the R90 lesson).
    my $ok = eval {
        my sub settle ($future, $what, $after = 20) {
            $loop->await(Future->wait_any(
                $future->without_cancel,
                $loop->timeout_future(after => $after)));
            die "$what did not resolve within ${after}s\n"
                unless $future->is_ready;
            return $future->get;
        }
        my sub proto ($full_name) {
            return Temporalio::Core::Proto::resolve($full_name);
        }

        my $client = settle(
            Temporalio::Client->connect($server->target, runtime => $runtime),
            'connect');

        # --- the accessors and their shape -------------------------------
        my $wf = $client->workflow_service;
        my $op = $client->operator_service;
        die "workflow_service returned no handle\n" unless defined $wf;
        die "operator_service returned no handle\n" unless defined $op;
        die "workflow_service handle lacks get_system_info\n"
            unless $wf->can('get_system_info');
        die "operator_service handle lacks add_search_attributes\n"
            unless $op->can('add_search_attributes');
        # Distinct per-service surfaces (Python has one generated class per
        # service): an operator RPC must not appear on the workflow handle.
        die "workflow_service handle wrongly exposes add_search_attributes\n"
            if $wf->can('add_search_attributes');
        die "operator_service handle wrongly exposes get_system_info\n"
            if $op->can('get_system_info');

        # --- workflow service: raw GetSystemInfo round-trip --------------
        my $info = settle($wf->get_system_info(
            proto('temporal.api.workflowservice.v1.GetSystemInfoRequest')
                ->new({})), 'raw GetSystemInfo');
        die 'GetSystemInfo decoded to the wrong class: ' . ref($info) . "\n"
            unless ref($info) =~ /GetSystemInfoResponse\z/;
        die "GetSystemInfo response carries no server version\n"
            unless defined $info->server_version
                && length $info->server_version;

        # --- operator service: add -> list -> remove ----------------------
        # INDEXED_VALUE_TYPE_KEYWORD = 2 (temporal.api.enums.v1, common.proto).
        my $attr = "PerlRawServiceProbe$$";
        settle($op->add_search_attributes(
            proto('temporal.api.operatorservice.v1.AddSearchAttributesRequest')
                ->new({
                    namespace         => 'default',
                    search_attributes => { $attr => 2 },
                })), 'operator AddSearchAttributes');

        my $listed = settle($op->list_search_attributes(
            proto('temporal.api.operatorservice.v1.ListSearchAttributesRequest')
                ->new({ namespace => 'default' })),
            'operator ListSearchAttributes');
        my $custom = $listed->custom_attributes // {};
        die "added search attribute '$attr' missing from the list\n"
            unless defined $custom->{$attr};
        die "added search attribute '$attr' has type $custom->{$attr},"
          . " expected 2 (Keyword)\n"
            unless $custom->{$attr} == 2;

        settle($op->remove_search_attributes(
            proto('temporal.api.operatorservice.v1.RemoveSearchAttributesRequest')
                ->new({
                    namespace         => 'default',
                    search_attributes => [$attr],
                })), 'operator RemoveSearchAttributes');
        my $after = settle($op->list_search_attributes(
            proto('temporal.api.operatorservice.v1.ListSearchAttributesRequest')
                ->new({ namespace => 'default' })),
            'operator ListSearchAttributes after remove');
        die "removed search attribute '$attr' still listed\n"
            if defined(($after->custom_attributes // {})->{$attr});

        $client->connection->close;
        1;
    };
    my $error = $@;
    $server->shutdown;
    $runtime->shutdown;
    die $error if !$ok;
    return 1;
}, timeout => 120);

T2->ok($live{ok},
    'raw workflow_service/operator_service handles: GetSystemInfo round-trips'
  . ' and operator search-attribute add/list/remove forms and sends')
    or T2->diag($live{reason});

T2->done_testing;
