# ABOUTME: Replay test harness (spec section 10.6) — drive a workflow Runner
# ABOUTME: with hand-built activations and read back the emitted commands. No
# ABOUTME: server, no worker, no IO::Async; pure deterministic replay.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Workflow::Runner ();
use Temporalio::Converter::Payload ();

class Temporalio::Test::WorkflowReplay {
    # The workflow Definition subclass under test (e.g. 'My::Workflow::Greeting').
    field $workflow_class :param;

    # Optional payload converter; defaults to the spec composite. Lets a test
    # inject a recording/custom converter.
    field $payload_converter :param = undef;

    # Worker-level outcome-policy options (spec section 10.3 step 6), threaded
    # to the Runner so a test can exercise the full completion decision table
    # (T-wf-13 / T-wf-15c). Defaults match a worker with no overrides.
    field $workflow_failure_exception_types :param = [];
    field $nondeterminism_as_workflow_fail   :param = 0;

    # The per-run Runner. Created lazily on the first push_activation so the
    # run_id from the activation seeds it (one harness drives one run, like
    # Python's WorkflowReplayer over a single run).
    field $runner;

    ADJUST {
        $payload_converter //= Temporalio::Converter::Payload->default;
    }

    # push_activation($activation) -> the decoded list of WorkflowCommand
    # objects from the resulting WorkflowActivationCompletion. The activation is
    # a coresdk WorkflowActivation proto (built by the caller). Subsequent calls
    # reuse the same Runner (the same run), mirroring how the worker feeds a
    # cached runner successive activations for one run id.
    method push_activation ($activation) {
        return $self->commands_of(
            $self->push_activation_completion($activation));
    }

    # push_activation_completion($activation) -> the fully-decoded
    # WorkflowActivationCompletion proto. Unlike push_activation (which returns
    # only the commands of a SUCCESSFUL completion), this exposes the raw
    # completion so a test can inspect a TASK-failure outcome (which_status eq
    # 'failed', spec section 10.3 step 6 / T-wf-15a).
    method push_activation_completion ($activation) {
        # Normalise the activation the way the real worker receives it: fully
        # decoded off the wire, with every nested message blessed and its
        # oneof discriminator (which_variant) live. A proto built via ->new
        # from a nested hashref leaves the sub-messages as plain hashrefs, so
        # round-trip it through encode/decode to match production exactly.
        $activation = ref($activation)->decode($activation->encode);

        $runner //= Temporalio::Workflow::Runner->new(
            workflow_class                   => $workflow_class,
            run_id                           => $activation->run_id,
            payload_converter                => $payload_converter,
            workflow_failure_exception_types => $workflow_failure_exception_types,
            nondeterminism_as_workflow_fail  => $nondeterminism_as_workflow_fail,
        );

        my $completion = $runner->process_activation($activation);

        # Round-trip the completion the way the worker hands it to core (encode
        # to bytes, decode back) so every nested message — Success/Failure, each
        # WorkflowCommand, its variant payloads — is fully blessed with live
        # accessors and oneof discriminators.
        return ref($completion)->decode($completion->encode);
    }

    # commands_of($completion) -> the WorkflowCommand list of a SUCCESSFUL
    # completion (empty for a `failed` completion, which carries no commands).
    method commands_of ($completion) {
        my $success = $completion->successful;
        return () unless defined $success;
        return ($success->commands // [])->@*;
    }

    # The Runner backing this harness (undef until the first push_activation).
    # Lets a test introspect runner state directly.
    method runner { return $runner }
}

1;

__END__

=head1 NAME

Temporalio::Test::WorkflowReplay - server-free replay harness for workflows

=head1 SYNOPSIS

    use Temporalio::Test::WorkflowReplay;

    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'My::Workflow::Greeting',
    );

    my @commands = $harness->push_activation(
        Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation->new({
            run_id    => 'r1',
            timestamp => { seconds => 100 },
            jobs      => [
                { initialize_workflow => {
                    workflow_type => 'Greeting',
                    arguments     => [
                        { metadata => { encoding => 'json/plain' }, data => '"Alice"' },
                    ],
                } },
            ],
        }),
    );
    # @commands is the decoded WorkflowCommand list from the completion.

=head1 DESCRIPTION

The replay test harness from spec section 10.6: it constructs a
L<Temporalio::Workflow::Runner> for C<workflow_class> and feeds it
hand-crafted activations, returning the commands the runner emits. No server,
no worker, no IO::Async event loop is involved — workflow Futures are resolved
imperatively by the runner from the activation jobs, so replay is fully
deterministic and synchronous.

C<push_activation> returns the decoded list of C<WorkflowCommand> protos from
the resulting C<WorkflowActivationCompletion>. Successive calls reuse the same
runner (the same workflow run), mirroring how the worker feeds a cached runner
successive activations.

=head1 METHODS

=over 4

=item C<push_activation($activation)>

Apply a C<coresdk.workflow_activation.WorkflowActivation> proto and return the
emitted C<WorkflowCommand> list (empty for a failed completion until P3.7).

=item C<runner>

The backing L<Temporalio::Workflow::Runner> (C<undef> before the first
C<push_activation>).

=back

=cut
