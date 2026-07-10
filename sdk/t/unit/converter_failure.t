# ABOUTME: Tests Temporalio::Converter::Failure: exception <-> Failure proto
# ABOUTME: round-trips, cause chains, the spec 5.3 info-type table, fallbacks.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Core::Proto;
use Temporalio::Converter::Failure;
use Temporalio::Converter::Payload;
use Temporalio::Exception::Application;
use Temporalio::Exception::Activity;
use Temporalio::Exception::Timeout;
use Temporalio::Exception::Cancelled;
use Temporalio::Exception::Terminated;
use Temporalio::Exception::Server;
use Temporalio::Exception::ResetWorkflow;
use Temporalio::Exception::ChildWorkflow;
use Temporalio::Exception::NexusHandler;
use Temporalio::Exception::NexusOperation;
use Temporalio::Exception::RpcError;

my $fc = Temporalio::Converter::Failure->new;
my $pc = Temporalio::Converter::Payload->default;

my $FAILURE = Temporalio::Core::Proto::resolve('temporal.api.failure.v1.Failure');

# Resolve one info class per spec 5.3 table row, for building protos directly.
my %INFO_CLASS = map {
    $_ => Temporalio::Core::Proto::resolve("temporal.api.failure.v1.$_")
} qw(
    ApplicationFailureInfo TimeoutFailureInfo CanceledFailureInfo
    TerminatedFailureInfo ServerFailureInfo ResetWorkflowFailureInfo
    ActivityFailureInfo ChildWorkflowExecutionFailureInfo
    NexusHandlerFailureInfo NexusOperationFailureInfo
);

T2->subtest('Application round-trips type/non_retryable/details (T-fail-1)' => sub {
    my $exc = Temporalio::Exception::Application->new(
        message       => 'oops',
        type          => 'X',
        non_retryable => 1,
        details       => ['a', 1],
    );
    my $failure = $fc->to_failure($exc, $pc);
    T2->isa_ok($failure, $FAILURE);
    T2->is($failure->which_failure_info, 'application_failure_info',
        'application info variant set');
    T2->is($failure->message, 'oops', 'proto message set');
    T2->is($failure->application_failure_info->type, 'X', 'proto type set');
    T2->ok($failure->application_failure_info->non_retryable,
        'proto non_retryable set');
    T2->ok(length($failure->stack_trace // ''), 'stack trace rendered');

    # Through the wire and back, then to an exception again.
    my $decoded = $FAILURE->decode($failure->encode);
    my $back    = $fc->from_failure($decoded, $pc);
    T2->isa_ok($back, 'Temporalio::Exception::Application');
    T2->is($back->message, 'oops', 'message survives');
    T2->is($back->type, 'X', 'type survives');
    T2->ok($back->non_retryable, 'non_retryable survives');
    T2->is($back->details, ['a', 1], 'details payloads survive');
    T2->is($back->category, 'application', 'category defaults');
});

T2->subtest('3-deep cause chain round-trips (T-fail-2)' => sub {
    my $root = Temporalio::Exception::Application->new(
        message => 'root cause',
        type    => 'RootError',
    );
    my $mid = Temporalio::Exception::Activity->new(
        message            => 'activity failed',
        activity_id        => 'a1',
        activity_type      => 'MyActivity',
        identity           => 'worker@host',
        retry_state        => 'in_progress',
        scheduled_event_id => 4,
        started_event_id   => 5,
        cause              => $root,
    );
    my $outer = Temporalio::Exception::Application->new(
        message => 'workflow-side wrapper',
        cause   => $mid,
    );

    my $failure = $fc->to_failure($outer, $pc);
    my $back    = $fc->from_failure($FAILURE->decode($failure->encode), $pc);

    T2->isa_ok($back, 'Temporalio::Exception::Application');
    T2->is($back->message, 'workflow-side wrapper', 'outer message');

    my $back_mid = $back->cause;
    T2->isa_ok($back_mid, 'Temporalio::Exception::Activity');
    T2->is($back_mid->message, 'activity failed', 'middle message');
    T2->is($back_mid->activity_id, 'a1', 'activity_id survives');
    T2->is($back_mid->activity_type, 'MyActivity', 'activity_type survives');
    T2->is($back_mid->identity, 'worker@host', 'identity survives');
    T2->is($back_mid->retry_state, 'in_progress', 'retry_state string survives');
    T2->is($back_mid->scheduled_event_id, 4, 'scheduled_event_id survives');
    T2->is($back_mid->started_event_id, 5, 'started_event_id survives');

    my $back_root = $back_mid->cause;
    T2->isa_ok($back_root, 'Temporalio::Exception::Application');
    T2->is($back_root->message, 'root cause', 'root message');
    T2->is($back_root->type, 'RootError', 'root type');
    T2->is($back_root->cause, undef, 'chain terminates');
});

T2->subtest('unknown failure_info falls back to Application, warns once (T-fail-3)' => sub {
    my $mystery = $FAILURE->new({ message => 'mystery failure' });

    my $first;
    my $warned = T2->warns(sub { $first = $fc->from_failure($mystery, $pc) });
    T2->is($warned, 1, 'first unknown info warns exactly once');
    T2->isa_ok($first, 'Temporalio::Exception::Application');
    T2->is($first->message, 'mystery failure', 'message preserved');

    my $again = T2->warns(sub { $fc->from_failure($mystery, $pc) });
    T2->is($again, 0, 'subsequent unknown infos stay silent (warns once)');
});

T2->subtest('plain string die becomes Application with Plain type (T-fail-4)' => sub {
    my $err = do { local $@; eval { die "kaboom\n" }; $@ };
    my $failure = $fc->to_failure($err, $pc);
    T2->is($failure->which_failure_info, 'application_failure_info',
        'non-exception encodes as application failure');
    T2->is($failure->message, 'kaboom', 'die string is the message');
    T2->is($failure->application_failure_info->type,
        'Temporalio::Exception::Plain', 'type marks a plain Perl death');

    my $back = $fc->from_failure($FAILURE->decode($failure->encode), $pc);
    T2->isa_ok($back, 'Temporalio::Exception::Application');
    T2->is($back->type, 'Temporalio::Exception::Plain', 'type survives');
});

# Spec 5.3 info-type mapping table, both directions. Each row: proto oneof
# field => [info instance for from_failure, exception class, extra ctor args].
my %ROWS = (
    application_failure_info => [
        $INFO_CLASS{ApplicationFailureInfo}->new({}),
        'Temporalio::Exception::Application', {},
    ],
    timeout_failure_info => [
        $INFO_CLASS{TimeoutFailureInfo}->new({ timeout_type => 2 }),
        'Temporalio::Exception::Timeout',
        { timeout_type => 'schedule_to_start' },
    ],
    canceled_failure_info => [
        $INFO_CLASS{CanceledFailureInfo}->new({}),
        'Temporalio::Exception::Cancelled', {},
    ],
    terminated_failure_info => [
        $INFO_CLASS{TerminatedFailureInfo}->new({}),
        'Temporalio::Exception::Terminated', {},
    ],
    server_failure_info => [
        $INFO_CLASS{ServerFailureInfo}->new({ non_retryable => 1 }),
        'Temporalio::Exception::Server', {},
    ],
    reset_workflow_failure_info => [
        $INFO_CLASS{ResetWorkflowFailureInfo}->new({}),
        'Temporalio::Exception::ResetWorkflow', {},
    ],
    activity_failure_info => [
        $INFO_CLASS{ActivityFailureInfo}->new({ activity_id => 'a1' }),
        'Temporalio::Exception::Activity', {},
    ],
    child_workflow_execution_failure_info => [
        $INFO_CLASS{ChildWorkflowExecutionFailureInfo}->new({ namespace => 'ns' }),
        'Temporalio::Exception::ChildWorkflow', {},
    ],
    nexus_handler_failure_info => [
        $INFO_CLASS{NexusHandlerFailureInfo}->new({ type => 'BAD_REQUEST' }),
        'Temporalio::Exception::NexusHandler', {},
    ],
    nexus_operation_execution_failure_info => [
        $INFO_CLASS{NexusOperationFailureInfo}->new({ endpoint => 'ep' }),
        'Temporalio::Exception::NexusOperation', {},
    ],
);

T2->subtest('spec 5.3 table: each info type dispatches to its class (table-driven)' => sub {
    for my $oneof (sort keys %ROWS) {
        my ($info, $class, $ctor) = @{ $ROWS{$oneof} };

        my $failure = $FAILURE->new({ message => 'm', $oneof => $info });
        my $exc = $fc->from_failure($FAILURE->decode($failure->encode), $pc);
        T2->isa_ok($exc, $class);

        my $encoded = $fc->to_failure($class->new(message => 'm', %$ctor), $pc);
        T2->is($encoded->which_failure_info, $oneof,
            "$class encodes as $oneof");
    }
});

T2->subtest('field-level enum and nested-message mapping' => sub {
    # Timeout: spec string <-> proto enum number.
    my $timeout = Temporalio::Exception::Timeout->new(
        message                => 'took too long',
        timeout_type           => 'heartbeat',
        last_heartbeat_details => [{ beat => 1 }],
    );
    my $tf = $fc->to_failure($timeout, $pc);
    T2->is($tf->timeout_failure_info->timeout_type, 4,
        'heartbeat maps to TIMEOUT_TYPE_HEARTBEAT (4)');
    my $timeout_back = $fc->from_failure($FAILURE->decode($tf->encode), $pc);
    T2->is($timeout_back->timeout_type, 'heartbeat', 'enum maps back to string');
    T2->is($timeout_back->last_heartbeat_details, [{ beat => 1 }],
        'heartbeat details payloads survive');

    # ChildWorkflow: nested WorkflowExecution / WorkflowType messages.
    my $child = Temporalio::Exception::ChildWorkflow->new(
        message            => 'child failed',
        namespace          => 'ns',
        workflow_id        => 'wf-1',
        run_id             => 'run-1',
        workflow_type      => 'ChildWf',
        retry_state        => 'maximum_attempts_reached',
        initiated_event_id => 9,
        started_event_id   => 10,
    );
    my $cf = $fc->to_failure($child, $pc);
    my $child_back = $fc->from_failure($FAILURE->decode($cf->encode), $pc);
    T2->is($child_back->workflow_id, 'wf-1', 'workflow_id via WorkflowExecution');
    T2->is($child_back->run_id, 'run-1', 'run_id via WorkflowExecution');
    T2->is($child_back->workflow_type, 'ChildWf', 'workflow_type via WorkflowType');
    T2->is($child_back->retry_state, 'maximum_attempts_reached',
        'retry_state enum string survives');
    T2->is($child_back->namespace, 'ns', 'namespace survives');

    # Exceptions outside the spec 5.3 table encode as a generic application
    # failure carrying the class name as the type.
    my $rpc = Temporalio::Exception::RpcError->new(
        message     => 'rpc broke',
        status_code => 5,
    );
    my $rf = $fc->to_failure($rpc, $pc);
    T2->is($rf->which_failure_info, 'application_failure_info',
        'unmapped exception class encodes as application failure');
    T2->is($rf->application_failure_info->type, 'Temporalio::Exception::RpcError',
        'type carries the original class name');
});

T2->done_testing;
