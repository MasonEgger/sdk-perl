# ABOUTME: Converts Temporalio::Exception::* instances to/from the Temporal
# ABOUTME: failure.v1.Failure proto, preserving cause chains (spec section 5.3).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Core::Proto ();
use Temporalio::Exception ();
use Temporalio::Exception::Application;
use Temporalio::Exception::Cancelled;
use Temporalio::Exception::Timeout;
use Temporalio::Exception::Terminated;
use Temporalio::Exception::Server;
use Temporalio::Exception::ResetWorkflow;
use Temporalio::Exception::Activity;
use Temporalio::Exception::ChildWorkflow;
use Temporalio::Exception::NexusHandler;
use Temporalio::Exception::NexusOperation;
use Temporalio::Exception::DataConverter ();

# Enum number <-> Temporal-spec string maps. The strings are the lowercased
# suffixes of the proto enum names (temporal/api/enums/v1/workflow.proto):
# TIMEOUT_TYPE_START_TO_CLOSE -> 'start_to_close', RETRY_STATE_IN_PROGRESS ->
# 'in_progress', and so on. 0 (UNSPECIFIED) maps to undef in both directions.
my %TIMEOUT_TYPE_NAME = (
    1 => 'start_to_close',
    2 => 'schedule_to_start',
    3 => 'schedule_to_close',
    4 => 'heartbeat',
);
my %TIMEOUT_TYPE_NUMBER = reverse %TIMEOUT_TYPE_NAME;

my %RETRY_STATE_NAME = (
    1 => 'in_progress',
    2 => 'non_retryable_failure',
    3 => 'timeout',
    4 => 'maximum_attempts_reached',
    5 => 'retry_policy_not_set',
    6 => 'internal_server_error',
    7 => 'cancel_requested',
);
my %RETRY_STATE_NUMBER = reverse %RETRY_STATE_NAME;

# Forward-compat warning for an unrecognized (or absent) failure_info: warn
# the first time only, per process (T-fail-3).
my $WARNED_UNKNOWN_INFO = 0;

# Proto classes, resolved once at require time (Temporalio::Core::Proto loads
# the vendored protos on first resolve).
my $FAILURE = Temporalio::Core::Proto::resolve('temporal.api.failure.v1.Failure');
my %INFO    = map {
    $_ => Temporalio::Core::Proto::resolve("temporal.api.failure.v1.$_")
} qw(
    ApplicationFailureInfo TimeoutFailureInfo CanceledFailureInfo
    TerminatedFailureInfo ServerFailureInfo ResetWorkflowFailureInfo
    ActivityFailureInfo ChildWorkflowExecutionFailureInfo
    NexusHandlerFailureInfo NexusOperationFailureInfo
);
my $PAYLOADS      = Temporalio::Core::Proto::resolve('temporal.api.common.v1.Payloads');
my $ACTIVITY_TYPE = Temporalio::Core::Proto::resolve('temporal.api.common.v1.ActivityType');
my $WF_EXECUTION  = Temporalio::Core::Proto::resolve('temporal.api.common.v1.WorkflowExecution');
my $WF_TYPE       = Temporalio::Core::Proto::resolve('temporal.api.common.v1.WorkflowType');

class Temporalio::Converter::Failure {

    # The default failure converter — spec section 5.1's
    # Temporalio::Converter::Failure->default (the converter is stateless,
    # so this is just a fresh instance).
    sub default ($class) { return $class->new }

    # temporal.api.enums.v1.ApplicationErrorCategory: UNSPECIFIED=0, BENIGN=1.
    # The Perl-level category strings are 'application' (the spec default,
    # encoding as UNSPECIFIED) and 'benign'.
    sub _category_number ($category) { ($category // '') eq 'benign' ? 1 : 0 }
    sub _category_name   ($number)   { ($number // 0) == 1 ? 'benign' : 'application' }

    # to_failure($exception, $payload_converter) -> Failure proto instance.
    # Non-Temporalio values (plain string deaths, foreign objects) are wrapped
    # as Application failures first: a plain string gets the sentinel type
    # 'Temporalio::Exception::Plain' (T-fail-4), a foreign object its class.
    method to_failure ($exception, $payload_converter) {
        if (!(Scalar::Util::blessed($exception)
            && $exception->isa('Temporalio::Exception')))
        {
            my $type = Scalar::Util::blessed($exception)
                // 'Temporalio::Exception::Plain';
            my $message = "$exception";
            chomp $message;
            $exception = Temporalio::Exception::Application->new(
                message => $message,
                type    => $type,
            );
        }

        my %fields = (message => $exception->message);

        if (defined(my $trace = $exception->stack_trace)) {
            $fields{stack_trace} =
                Scalar::Util::blessed($trace) && $trace->can('as_string')
                ? $trace->as_string
                : "$trace";
        }
        if (defined(my $cause = $exception->cause)) {
            $fields{cause} = $self->to_failure($cause, $payload_converter);
        }

        my ($info_field, $info) = $self->_info_for($exception, $payload_converter);
        $fields{$info_field} = $info;

        return $FAILURE->new(\%fields);
    }

    # from_failure($failure, $payload_converter) -> Temporalio::Exception::*.
    # An unrecognized (or absent) failure_info variant degrades to a generic
    # Application failure with the message preserved, warning once (T-fail-3).
    method from_failure ($failure, $payload_converter) {
        # Normalize through the wire so every nested field — whatever mix of
        # hashrefs and instances the caller built — is a materialized class
        # instance with working accessors.
        $failure = $FAILURE->decode($failure->encode);

        my %common;
        if (defined(my $trace = $failure->stack_trace)) {
            $common{stack_trace} = $trace if length $trace;
        }
        if (defined(my $cause = $failure->cause)) {
            $common{cause} = $self->from_failure($cause, $payload_converter);
        }

        my $which = $failure->which_failure_info // '';
        my $builder = $self->can("_from_$which");
        unless ($builder) {
            warn "Temporalio::Converter::Failure: unrecognized failure_info"
                . ($which ne '' ? " '$which'" : '')
                . " - converting to a generic Application failure\n"
                unless $WARNED_UNKNOWN_INFO++;
            return Temporalio::Exception::Application->new(
                message => $self->_message($failure, 'Failure error'),
                %common,
            );
        }
        return $builder->($self, $failure, $payload_converter, %common);
    }

    # --- to_failure dispatch: one (oneof field, info message) per class -----

    method _info_for ($exception, $pc) {
        if ($exception->isa('Temporalio::Exception::Cancelled')) {
            return (canceled_failure_info => $INFO{CanceledFailureInfo}->new({
                $self->_maybe_payloads(details => $exception->details, $pc),
            }));
        }
        if ($exception->isa('Temporalio::Exception::Timeout')) {
            return (timeout_failure_info => $INFO{TimeoutFailureInfo}->new({
                timeout_type =>
                    $self->_enum_number(\%TIMEOUT_TYPE_NUMBER, 'timeout_type',
                        $exception->timeout_type),
                $self->_maybe_payloads(last_heartbeat_details =>
                    $exception->last_heartbeat_details, $pc),
            }));
        }
        if ($exception->isa('Temporalio::Exception::Terminated')) {
            return (terminated_failure_info =>
                $INFO{TerminatedFailureInfo}->new({}));
        }
        if ($exception->isa('Temporalio::Exception::Server')) {
            return (server_failure_info => $INFO{ServerFailureInfo}->new({
                non_retryable => $exception->non_retryable ? 1 : 0,
            }));
        }
        if ($exception->isa('Temporalio::Exception::ResetWorkflow')) {
            return (reset_workflow_failure_info =>
                $INFO{ResetWorkflowFailureInfo}->new({
                    $self->_maybe_payloads(last_heartbeat_details =>
                        $exception->last_heartbeat_details, $pc),
                }));
        }
        if ($exception->isa('Temporalio::Exception::Activity')) {
            return (activity_failure_info => $INFO{ActivityFailureInfo}->new({
                scheduled_event_id => $exception->scheduled_event_id // 0,
                started_event_id   => $exception->started_event_id // 0,
                identity           => $exception->identity // '',
                activity_id        => $exception->activity_id // '',
                (defined $exception->activity_type
                    ? (activity_type =>
                        $ACTIVITY_TYPE->new({ name => $exception->activity_type }))
                    : ()),
                retry_state =>
                    $self->_enum_number(\%RETRY_STATE_NUMBER, 'retry_state',
                        $exception->retry_state),
            }));
        }
        if ($exception->isa('Temporalio::Exception::ChildWorkflow')) {
            return (child_workflow_execution_failure_info =>
                $INFO{ChildWorkflowExecutionFailureInfo}->new({
                    namespace          => $exception->namespace // '',
                    workflow_execution => $WF_EXECUTION->new({
                        workflow_id => $exception->workflow_id // '',
                        run_id      => $exception->run_id // '',
                    }),
                    (defined $exception->workflow_type
                        ? (workflow_type =>
                            $WF_TYPE->new({ name => $exception->workflow_type }))
                        : ()),
                    initiated_event_id => $exception->initiated_event_id // 0,
                    started_event_id   => $exception->started_event_id // 0,
                    retry_state        =>
                        $self->_enum_number(\%RETRY_STATE_NUMBER, 'retry_state',
                            $exception->retry_state),
                }));
        }
        if ($exception->isa('Temporalio::Exception::NexusHandler')) {
            return (nexus_handler_failure_info =>
                $INFO{NexusHandlerFailureInfo}->new({
                    type           => $exception->type // '',
                    retry_behavior => $exception->retry_behavior // 0,
                }));
        }
        if ($exception->isa('Temporalio::Exception::NexusOperation')) {
            return (nexus_operation_execution_failure_info =>
                $INFO{NexusOperationFailureInfo}->new({
                    scheduled_event_id => $exception->scheduled_event_id // 0,
                    endpoint           => $exception->endpoint // '',
                    service            => $exception->service // '',
                    operation          => $exception->operation // '',
                    operation_token    => $exception->operation_token // '',
                }));
        }
        if ($exception->isa('Temporalio::Exception::Application')) {
            return (application_failure_info =>
                $INFO{ApplicationFailureInfo}->new({
                    (defined $exception->type
                        ? (type => $exception->type) : ()),
                    non_retryable => $exception->non_retryable ? 1 : 0,
                    $self->_maybe_payloads(details => $exception->details, $pc),
                    category => _category_number($exception->category),
                }));
        }
        # A Temporalio exception outside the spec 5.3 table (RpcError,
        # Argument, Bridge, ...): generic application failure carrying the
        # class name as the type, mirroring the reference SDKs.
        return (application_failure_info => $INFO{ApplicationFailureInfo}->new({
            type => Scalar::Util::blessed($exception),
        }));
    }

    # --- from_failure builders: one per oneof variant ------------------------

    method _from_application_failure_info ($failure, $pc, %common) {
        my $info = $failure->application_failure_info;
        return Temporalio::Exception::Application->new(
            message       => $self->_message($failure, 'Application error'),
            type          => $info->type,
            non_retryable => $info->non_retryable ? 1 : 0,
            details       => $self->_from_payloads($info->details, $pc),
            category      => _category_name($info->category),
            %common,
        );
    }

    method _from_timeout_failure_info ($failure, $pc, %common) {
        my $info = $failure->timeout_failure_info;
        return Temporalio::Exception::Timeout->new(
            message      => $self->_message($failure, 'Timeout'),
            timeout_type => $TIMEOUT_TYPE_NAME{ $info->timeout_type // 0 },
            last_heartbeat_details =>
                $self->_from_payloads($info->last_heartbeat_details, $pc),
            %common,
        );
    }

    method _from_canceled_failure_info ($failure, $pc, %common) {
        my $info = $failure->canceled_failure_info;
        return Temporalio::Exception::Cancelled->new(
            message => $self->_message($failure, 'Cancelled'),
            details => $self->_from_payloads($info->details, $pc),
            %common,
        );
    }

    method _from_terminated_failure_info ($failure, $pc, %common) {
        return Temporalio::Exception::Terminated->new(
            message => $self->_message($failure, 'Terminated'),
            %common,
        );
    }

    method _from_server_failure_info ($failure, $pc, %common) {
        my $info = $failure->server_failure_info;
        return Temporalio::Exception::Server->new(
            message       => $self->_message($failure, 'Server error'),
            non_retryable => $info->non_retryable ? 1 : 0,
            %common,
        );
    }

    method _from_reset_workflow_failure_info ($failure, $pc, %common) {
        my $info = $failure->reset_workflow_failure_info;
        return Temporalio::Exception::ResetWorkflow->new(
            message => $self->_message($failure, 'Reset workflow error'),
            last_heartbeat_details =>
                $self->_from_payloads($info->last_heartbeat_details, $pc),
            %common,
        );
    }

    method _from_activity_failure_info ($failure, $pc, %common) {
        my $info = $failure->activity_failure_info;
        return Temporalio::Exception::Activity->new(
            message            => $self->_message($failure, 'Activity error'),
            scheduled_event_id => $info->scheduled_event_id,
            started_event_id   => $info->started_event_id,
            identity           => $info->identity,
            activity_type      =>
                defined $info->activity_type ? $info->activity_type->name : undef,
            activity_id        => $info->activity_id,
            retry_state        => $RETRY_STATE_NAME{ $info->retry_state // 0 },
            %common,
        );
    }

    method _from_child_workflow_execution_failure_info ($failure, $pc, %common) {
        my $info      = $failure->child_workflow_execution_failure_info;
        my $execution = $info->workflow_execution;
        return Temporalio::Exception::ChildWorkflow->new(
            message     => $self->_message($failure, 'Child workflow error'),
            namespace   => $info->namespace,
            workflow_id => defined $execution ? $execution->workflow_id : undef,
            run_id      => defined $execution ? $execution->run_id : undef,
            workflow_type =>
                defined $info->workflow_type ? $info->workflow_type->name : undef,
            initiated_event_id => $info->initiated_event_id,
            started_event_id   => $info->started_event_id,
            retry_state        => $RETRY_STATE_NAME{ $info->retry_state // 0 },
            %common,
        );
    }

    method _from_nexus_handler_failure_info ($failure, $pc, %common) {
        my $info = $failure->nexus_handler_failure_info;
        return Temporalio::Exception::NexusHandler->new(
            message        => $self->_message($failure, 'Nexus handler error'),
            type           => $info->type,
            retry_behavior => $info->retry_behavior,
            %common,
        );
    }

    method _from_nexus_operation_execution_failure_info ($failure, $pc, %common) {
        my $info = $failure->nexus_operation_execution_failure_info;
        return Temporalio::Exception::NexusOperation->new(
            message => $self->_message($failure, 'Nexus operation error'),
            scheduled_event_id => $info->scheduled_event_id,
            endpoint           => $info->endpoint,
            service            => $info->service,
            operation          => $info->operation,
            operation_token    => $info->operation_token,
            %common,
        );
    }

    # --- shared helpers -------------------------------------------------------

    # The proto message, or the reference-SDK per-class default when empty.
    method _message ($failure, $default) {
        my $message = $failure->message;
        return defined $message && length $message ? $message : $default;
    }

    # (field => Payloads instance) when $values is a non-empty arrayref, else
    # nothing — absent details stay absent on the wire (reference SDKs agree).
    method _maybe_payloads ($field, $values, $pc) {
        return () unless defined $values && @$values;
        return ($field => $PAYLOADS->new({
            payloads => [map { $pc->to_payload($_) } @$values],
        }));
    }

    # Payloads message -> arrayref of decoded values; undef when absent.
    method _from_payloads ($payloads, $pc) {
        return undef unless defined $payloads;
        return [map { $pc->from_payload($_) } @{ $payloads->payloads }];
    }

    # Spec string -> proto enum number; undef -> 0 (UNSPECIFIED), an unknown
    # string raises DataConverter rather than silently dropping data.
    method _enum_number ($table, $what, $name) {
        return 0 unless defined $name;
        return $table->{$name}
            // Temporalio::Exception::DataConverter->throw(
                message => "unknown $what '$name'");
    }
}

1;

__END__

=head1 NAME

Temporalio::Converter::Failure - exception / Failure proto converter

=head1 SYNOPSIS

    use Temporalio::Converter::Failure;
    use Temporalio::Converter::Payload;

    my $fc = Temporalio::Converter::Failure->default;   # same as ->new
    my $pc = Temporalio::Converter::Payload->default;

    my $failure   = $fc->to_failure($exception, $pc);
    my $exception = $fc->from_failure($failure, $pc);

=head1 DESCRIPTION

Converts between L<Temporalio::Exception> instances and
C<temporal.api.failure.v1.Failure> proto messages, preserving the C<cause>
chain in both directions (spec section 5.3). The failure-info variant
mapping follows the Temporal spec exactly:

    application_failure_info               Temporalio::Exception::Application
    timeout_failure_info                   Temporalio::Exception::Timeout
    canceled_failure_info                  Temporalio::Exception::Cancelled
    terminated_failure_info                Temporalio::Exception::Terminated
    server_failure_info                    Temporalio::Exception::Server
    reset_workflow_failure_info            Temporalio::Exception::ResetWorkflow
    activity_failure_info                  Temporalio::Exception::Activity
    child_workflow_execution_failure_info  Temporalio::Exception::ChildWorkflow
    nexus_handler_failure_info             Temporalio::Exception::NexusHandler
    nexus_operation_execution_failure_info Temporalio::Exception::NexusOperation

Embedded payload lists (C<details>, C<last_heartbeat_details>) are converted
through the supplied L<Temporalio::Converter::Payload>. Enum-valued fields
cross the boundary as Temporal-spec strings on the Perl side — the lowercased
suffix of the proto enum name (C<start_to_close>, C<in_progress>, ...) — and
as numbers on the proto side; 0/UNSPECIFIED maps to C<undef>.

=head1 BEHAVIOR NOTES

=over 4

=item *

C<to_failure> wraps non-Temporalio errors as Application failures first: a
plain string death gets the sentinel type C<Temporalio::Exception::Plain>,
a foreign blessed object its class name. Temporalio exceptions outside the
table above (RpcError, Argument, ...) encode as a generic application
failure with the class name as the type.

=item *

C<from_failure> converts an unrecognized (or absent) failure-info variant to
a generic L<Temporalio::Exception::Application> with the message preserved,
warning once per process (forward compatibility).

=item *

The Perl-side C<category> strings C<application> (default) and C<benign> map
to C<APPLICATION_ERROR_CATEGORY_UNSPECIFIED> and
C<APPLICATION_ERROR_CATEGORY_BENIGN> respectively.

=back

=cut
