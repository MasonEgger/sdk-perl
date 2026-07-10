# ABOUTME: Fixture workflow exercising the runtime handler getters/unset plus a
# ABOUTME: runtime query and update handler — drives runtime_handler_registration.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run body performs the getter identity checks synchronously (spec R86:
# get_*_handler returns the installed coderef; setting undef removes it; a
# compile-time attribute handler is visible through the same getter), installs
# a runtime query handler ('qstate') and a runtime update handler ('bump',
# with a validator), then parks until 'finish'. The returned string encodes
# each check as name=0/1 so the replay test asserts them all at once.
class WfDef::RuntimeHandlerGetters :isa(Temporalio::Workflow::Definition) {
    field $counter = 0;
    field $done    = 0;

    async method run :Run () {
        my @checks;
        my $same = sub ($got, $want) {
            return (defined $got && Scalar::Util::refaddr($got)
                    == Scalar::Util::refaddr($want)) ? 1 : 0;
        };

        # Named signal: set -> get returns the same coderef; undef unsets.
        my $sig = sub (@args) { return };
        Temporalio::Workflow->set_signal_handler('tmp_sig', $sig);
        push @checks, 'sig_get=' . $same->(
            Temporalio::Workflow->get_signal_handler('tmp_sig'), $sig);
        Temporalio::Workflow->set_signal_handler('tmp_sig', undef);
        push @checks, 'sig_unset=' . (
            defined Temporalio::Workflow->get_signal_handler('tmp_sig') ? 0 : 1);

        # A compile-time :Signal handler is visible through the same getter
        # (one lookup path over the attribute registry and the runtime table).
        push @checks, 'attr_get=' . (
            defined Temporalio::Workflow->get_signal_handler('finish') ? 1 : 0);

        # Query: identity + unset; 'qstate' stays installed for the test's
        # QueryWorkflow job.
        my $q = sub () { return "count=$counter" };
        Temporalio::Workflow->set_query_handler('qstate', $q);
        push @checks, 'query_get=' . $same->(
            Temporalio::Workflow->get_query_handler('qstate'), $q);
        Temporalio::Workflow->set_query_handler('tmp_query', sub () { return 'x' });
        Temporalio::Workflow->set_query_handler('tmp_query', undef);
        push @checks, 'query_unset=' . (
            defined Temporalio::Workflow->get_query_handler('tmp_query') ? 0 : 1);

        # Update: identity + unset; 'bump' (handler + validator) stays
        # installed for the test's DoUpdate jobs.
        my $u = sub ($n) { $counter += $n; return $counter };
        Temporalio::Workflow->set_update_handler('bump', $u,
            validator => sub ($n) {
                die "bump amount must be positive\n" if $n <= 0;
                return;
            });
        push @checks, 'update_get=' . $same->(
            Temporalio::Workflow->get_update_handler('bump'), $u);
        Temporalio::Workflow->set_update_handler('tmp_update', sub { return });
        Temporalio::Workflow->set_update_handler('tmp_update', undef);
        push @checks, 'update_unset=' . (
            defined Temporalio::Workflow->get_update_handler('tmp_update') ? 0 : 1);

        await Temporalio::Workflow::wait_condition(sub { $done });
        return join(',', @checks);
    }

    method finish :Signal('finish') () { $done = 1; return }
}

1;
