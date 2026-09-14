# ABOUTME: Replay tests for the update validator on every registration path
# ABOUTME: (spec R86 + F7, I9, closes #9): runtime dynamic validators, an
# ABOUTME: ATTRIBUTE :UpdateValidator paired with :Update(dynamic=1), the
# ABOUTME: no-fallback rule, install/uninstall symmetry, the inbound chain's
# ABOUTME: validate_update, and the synchronous-validator guard.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Converter::Payload;
use Temporalio::Worker::Interceptor ();

no warnings 'experimental::class';

# ---------------------------------------------------------------------------
# Interceptor fixtures. Declared BEFORE any signatured helper sub (the F::AA
# parser rule, lessons.md 2026-07-09) and signature-less throughout.
#
# RecordingInbound records validate_update and handle_update on a shared trace
# and delegates, the Perl analog of sdk-python's
# _TracingWorkflowInboundInterceptor: an inbound override MUST see
# handle_update_validator for every update that has a validator
# (_workflow_instance.py:650 calls self._inbound.handle_update_validator).
# ---------------------------------------------------------------------------
class RecordingInbound :isa(Temporalio::Worker::WorkflowInbound) {
    field $trace :param;
    method validate_update {
        push @$trace, 'validate:' . ($_[0]->get('update') // '');
        return $self->next->validate_update($_[0]);
    }
    method handle_update {
        push @$trace, 'handle:' . ($_[0]->get('update') // '');
        return $self->next->handle_update($_[0]);
    }
}

class RecordingInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $trace :param;
    method intercept_workflow {
        return RecordingInbound->new(next => $_[0], trace => $trace);
    }
}

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# A DoUpdate job with run_validator on (the server asks for validation on the
# first, non-replay delivery); ids are derived from the protocol instance id so
# each call site names it once.
sub do_update_job ($pi, $name, @args) {
    return { do_update => {
        id                   => "u-$pi",
        protocol_instance_id => $pi,
        name                 => $name,
        input                => [ map { payload($_) } @args ],
        run_validator        => 1,
    } };
}

sub signal_job ($name) {
    return { signal_workflow => { signal_name => $name, input => [] } };
}

# Push one activation carrying a single DoUpdate and return its UpdateResponse
# commands in order.
sub update_responses ($harness, $seconds, $pi, $name, @args) {
    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => $seconds },
        jobs      => [ do_update_job($pi, $name, @args) ],
    }));
    return grep { $_->which_variant eq 'update_response' } @cmds;
}

# Push a bare InitializeWorkflow so the :Run body reaches its first await (and
# any runtime handler registration in its prologue takes effect) before the
# updates under test arrive. InitializeWorkflow drains buffered pre-init
# updates BEFORE the body starts, so a DoUpdate in the SAME activation would
# still see nothing registered.
sub init_harness ($class, %opts) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => $class, %opts);
    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => $class =~ s/\AWfDef:://r,
            arguments     => [],
        } } ],
    }));
    return $harness;
}

# ---------------------------------------------------------------------------
# The dynamic handler and its validator are installed synchronously in the
# :Run body's prologue (before its first await). InitializeWorkflow drains any
# buffered pre-init updates BEFORE the :Run body starts (spec section 19.2 /
# Runner.pm _apply_initialize), so a DoUpdate ordered in the SAME activation as
# InitializeWorkflow would still see no dynamic handler registered. Each test
# therefore pushes a bare init activation first (letting the body run to its
# first await and register the handler+validator), then a SEPARATE activation
# carrying the DoUpdate.
# ---------------------------------------------------------------------------

# A validator that throws produces a single rejected{failure}: no accepted, no
# completed. The handler never runs.
T2->subtest('dynamic validator rejection emits a single rejected' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DynUpdateValidator',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DynUpdateValidator',
                arguments     => [],
            } },
        ],
    }));

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-1',
                name                 => 'whatever',
                input                => [ payload('reject-me') ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 1, 'exactly one UpdateResponse command');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the single UpdateResponse is rejected (the dynamic handler did not run)');
    T2->is($ur[0]->update_response->protocol_instance_id, 'pi-1',
        'rejected carries the protocol_instance_id');
    T2->ok(defined $ur[0]->update_response->rejected,
        'rejected carries a failure');
});

# An admitted argument passes the dynamic validator; the dynamic handler then
# runs and completes.
T2->subtest('dynamic validator admits, dynamic handler runs' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DynUpdateValidator',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DynUpdateValidator',
                arguments     => [],
            } },
        ],
    }));

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { do_update => {
                id                   => 'u-2',
                protocol_instance_id => 'pi-2',
                name                 => 'whatever',
                input                => [ payload('fine') ],
                run_validator        => 1,
            } },
        ],
    }));

    my @ur = grep { $_->which_variant eq 'update_response' } @cmds;
    T2->is(scalar @ur, 2, 'accepted then completed');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the admitted update is accepted');
    T2->is($ur[1]->update_response->which_response, 'completed',
        'the dynamic handler ran and completed');
    T2->is($PC->from_payload($ur[1]->update_response->completed),
        'whatever=fine|validator_saw=whatever=fine',
        'the dynamic handler got (name, @args), and the validator saw the '
        . 'SAME (name, @args) the handler did');
});

# A dynamic validator that issues a command is a WORKFLOW TASK FAILURE, matching
# the named-validator read-only guard (WfDef::MutatingValidator / T-upd-10).
T2->subtest('dynamic validator issuing a command -> task failure' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DynUpdateValidatorViolation',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DynUpdateValidatorViolation',
                arguments     => [],
            } },
        ],
    }));

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { do_update => {
                id                   => 'u-3',
                protocol_instance_id => 'pi-3',
                name                 => 'whatever',
                input                => [ payload('x') ],
                run_validator        => 1,
            } },
        ],
    }));

    T2->is($completion->which_status, 'failed',
        'a command-issuing dynamic validator fails the workflow task');
});

# ---------------------------------------------------------------------------
# Spec F7: the ATTRIBUTE registration path. An :UpdateValidator naming a
# :Update(dynamic=1) method is the Perl spelling of sdk-python's
# @workflow.update(dynamic=True) + @fn.validator (workflow/_handlers.py:382),
# and must be wired into the dynamic definition's validator slot exactly like
# a runtime one.
# ---------------------------------------------------------------------------

T2->subtest('attribute validator on a dynamic :Update rejects' => sub {
    my $harness = init_harness('WfDef::AttrDynUpdateValidator');

    my @ur = update_responses($harness, 101, 'pi-a1', 'whatever', 'reject-me');
    T2->is(scalar @ur, 1, 'exactly one UpdateResponse command');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the attribute-declared dynamic validator rejected the update');

    my $failure = $ur[0]->update_response->rejected;
    T2->is($failure->message, 'rejected by the attribute dynamic validator',
        'the rejection carries the validator message');
    T2->is($failure->application_failure_info->type, 'AttrDynamicReject',
        'the rejection carries the validator failure type');
});

T2->subtest('attribute dynamic validator admits, dynamic handler runs' => sub {
    my $harness = init_harness('WfDef::AttrDynUpdateValidator');

    my @ur = update_responses($harness, 101, 'pi-a2', 'whatever', 'fine');
    T2->is(scalar @ur, 2, 'accepted then completed');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the admitted update is accepted');
    T2->is($PC->from_payload($ur[1]->update_response->completed),
        'dyn:whatever=fine',
        'the dynamic handler ran with (name, @args)');
});

# The no-fallback rule (sdk-python _workflow_instance.py:2938-2941: "we
# shouldn't fall back to the dynamic validator for some defined, named update
# which doesn't have a defined validator"). `plain` has no validator of its
# own; the dynamic validator would reject this argument, so an accepted
# update is the proof it was never consulted. This subtest goes RED if
# _resolve_update_validator ever grows a named-to-dynamic `//` fallback.
T2->subtest('a named update without a validator is not validated by the dynamic one' => sub {
    my $harness = init_harness('WfDef::AttrDynUpdateValidator');

    my @ur = update_responses($harness, 101, 'pi-a3', 'plain', 'reject-me');
    T2->is(scalar @ur, 2, 'accepted then completed (no rejection)');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the named update is accepted unvalidated');
    T2->is($PC->from_payload($ur[1]->update_response->completed),
        'plain=reject-me',
        'the named handler ran on the argument the dynamic validator hates');
});

T2->subtest('a named attribute validator rejects with its own message and type' => sub {
    my $harness = init_harness('WfDef::AttrDynUpdateValidator');

    my @ur = update_responses($harness, 101, 'pi-a4', 'guarded', 'reject-me');
    T2->is(scalar @ur, 1, 'exactly one UpdateResponse command');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the named attribute validator rejected the update');

    my $failure = $ur[0]->update_response->rejected;
    T2->is($failure->message, 'rejected by the named attribute validator',
        'the rejection carries the named validator message');
    T2->is($failure->application_failure_info->type, 'NamedAttrReject',
        'the rejection carries the named validator failure type, not the '
        . 'dynamic one');
});

# ---------------------------------------------------------------------------
# Spec F7: install/uninstall symmetry for the RUNTIME dynamic registration.
# workflow_set_update_handler replaces the definition wholesale (sdk-python
# _workflow_instance.py:1428-1447 builds a fresh _UpdateDefinition), so an
# omitted validator clears the previous one and removing the handler takes its
# validator with it.
# ---------------------------------------------------------------------------
T2->subtest('dynamic validator install/uninstall symmetry' => sub {
    my $harness = init_harness('WfDef::DynUpdateValidatorReinstall');

    my @ur = update_responses($harness, 101, 'pi-b1', 'anything', 'x');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the installed validator rejects');

    # Re-install the handler with NO validator: the previous one is dropped.
    $harness->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ signal_job('drop_validator') ],
    }));
    @ur = update_responses($harness, 103, 'pi-b2', 'anything', 'x');
    T2->is(scalar @ur, 2, 'accepted then completed');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'an omitted validator cleared the previous dynamic validator');

    # Re-install WITH the validator: it is honored again.
    $harness->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 104 },
        jobs   => [ signal_job('restore') ],
    }));
    @ur = update_responses($harness, 105, 'pi-b3', 'anything', 'x');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the re-installed validator rejects again');

    # Remove the handler, then install it alone: removing the handler dropped
    # the validator, so nothing carries over.
    $harness->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 106 },
        jobs   => [ signal_job('remove_then_reinstall') ],
    }));
    @ur = update_responses($harness, 107, 'pi-b4', 'anything', 'x');
    T2->is(scalar @ur, 2, 'accepted then completed');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'removing the handler dropped its validator');
});

# The two spellings are not independent registries: an attribute
# :UpdateValidator naming the :Update(dynamic=1) method is promoted into the
# same dynamic slot the runtime path writes, so precedence has to be pinned.
# A runtime install replaces that slot wholesale (runtime wins; there is no
# merge), which takes the attribute-promoted validator with it when the
# install omits one. Same rule as the symmetry subtest above, reached from the
# attribute side.
T2->subtest('a runtime dynamic install replaces the attribute dynamic validator' => sub {
    my $harness = init_harness('WfDef::AttrDynUpdateValidator');

    my @ur = update_responses($harness, 101, 'pi-e1', 'whatever', 'reject-me');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the attribute dynamic validator rejects before the runtime install');
    T2->is($ur[0]->update_response->rejected->application_failure_info->type,
        'AttrDynamicReject',
        'the attribute dynamic validator is the one that ran');

    $harness->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ signal_job('install_runtime_dynamic') ],
    }));

    @ur = update_responses($harness, 103, 'pi-e2', 'whatever', 'reject-me');
    T2->is(scalar @ur, 2, 'accepted then completed (no rejection)');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the runtime install with no validator dropped the attribute one');
    T2->is($PC->from_payload($ur[1]->update_response->completed),
        'runtime:whatever=reject-me',
        'the runtime handler replaced the attribute dynamic handler too');
});

# ---------------------------------------------------------------------------
# Spec F7: the validator runs through the workflow-INBOUND chain, so an
# interceptor overriding validate_update observes it. sdk-python calls
# self._inbound.handle_update_validator(handler_input) inside the read-only
# scope (_workflow_instance.py:650) rather than invoking the validator
# directly.
# ---------------------------------------------------------------------------
T2->subtest('an inbound interceptor observes validate_update for a named update' => sub {
    my @trace;
    my $harness = init_harness('WfDef::AttrDynUpdateValidator',
        interceptors => [ RecordingInterceptor->new(trace => \@trace) ]);

    my @ur = update_responses($harness, 101, 'pi-c1', 'guarded', 'fine');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the update is accepted');
    T2->is(\@trace, [ 'validate:guarded', 'handle:guarded' ],
        'the chain saw validate_update before handle_update');
});

T2->subtest('an inbound interceptor observes validate_update for a dynamic update' => sub {
    my @trace;
    my $harness = init_harness('WfDef::AttrDynUpdateValidator',
        interceptors => [ RecordingInterceptor->new(trace => \@trace) ]);

    my @ur = update_responses($harness, 101, 'pi-c2', 'whatever', 'fine');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the dynamic update is accepted');
    T2->is(\@trace, [ 'validate:whatever', 'handle:whatever' ],
        'the chain saw validate_update for the dynamic update under the '
        . 'update NAME, not the dynamic method name');
});

T2->subtest('a rejecting validator stops the chain before handle_update' => sub {
    my @trace;
    my $harness = init_harness('WfDef::AttrDynUpdateValidator',
        interceptors => [ RecordingInterceptor->new(trace => \@trace) ]);

    my @ur = update_responses($harness, 101, 'pi-c3', 'guarded', 'reject-me');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the update is rejected');
    T2->is(\@trace, [ 'validate:guarded' ],
        'handle_update never reached the chain');
});

# ---------------------------------------------------------------------------
# Spec F7: validators are SYNCHRONOUS. sdk-python calls the validator as
# `handler(*input.args)` with no await (_workflow_instance.py:2938-2945), so an
# async validator there yields an un-awaited coroutine and the update is
# accepted unvalidated. Perl sees the same mistake as a Future that is not
# ready, and rejects the update with a message naming the fix rather than
# accepting it or wedging the workflow task.
# ---------------------------------------------------------------------------
T2->subtest('a validator returning a pending Future rejects the update' => sub {
    my $harness = init_harness('WfDef::AsyncUpdateValidator');

    my @ur = update_responses($harness, 101, 'pi-d1', 'slow', 'x');
    T2->is(scalar @ur, 1, 'exactly one UpdateResponse command');
    T2->is($ur[0]->update_response->which_response, 'rejected',
        'the update is rejected, not accepted unvalidated');
    T2->like($ur[0]->update_response->rejected->message,
        qr/must be synchronous/,
        'the rejection names the synchronous-validator contract');
    T2->like($ur[0]->update_response->rejected->message, qr/'slow'/,
        'the rejection names the update whose validator misbehaved');
    # The failure TYPE is the documented half of the contract (Workflow.pm
    # set_update_handler, Definition.pm :UpdateValidator): callers match on it
    # rather than on prose. Pinned so renaming the type in Runner.pm cannot
    # break the POD contract while the suite stays green.
    T2->is($ur[0]->update_response->rejected->application_failure_info->type,
        'AsyncUpdateValidator',
        'the rejection carries the documented AsyncUpdateValidator type');
});

T2->done_testing;
