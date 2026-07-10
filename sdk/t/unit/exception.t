# ABOUTME: Tests Temporalio::Exception base class and every concrete subclass in
# ABOUTME: spec section 6.2: construction, throw, cause chain, fields, isa chains.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util qw(blessed);
use Devel::StackTrace ();

use Temporalio::Exception;
use Temporalio::Exception::Argument;
use Temporalio::Exception::Runtime;
use Temporalio::Exception::Bridge;

# Spec section 6.1: base class with fields message/stack_trace/cause,
# class-method throw, overloaded stringification with the cause chain.

T2->subtest('construction and accessors (T-exc-1 shape)' => sub {
    my $exc = Temporalio::Exception->new(message => 'x');
    T2->isa_ok($exc, 'Temporalio::Exception');
    T2->is($exc->message, 'x', 'message accessor returns constructor value');
    T2->is($exc->cause, undef, 'cause defaults to undef');
});

T2->subtest('throw dies with a catchable object (T-exc-2)' => sub {
    my $ok = eval { Temporalio::Exception->throw(message => 'boom'); 1 };
    T2->ok(!$ok, 'throw dies');
    my $err = $@;
    T2->ok(blessed($err), 'died with an object, not a string');
    T2->isa_ok($err, 'Temporalio::Exception');
    T2->is($err->message, 'boom', 'thrown object carries the message');
});

T2->subtest('subclasses inherit construction, throw, and isa chain' => sub {
    for my $subclass (qw(Argument Runtime Bridge)) {
        my $class = "Temporalio::Exception::$subclass";
        my $exc = $class->new(message => 'm');
        T2->isa_ok($exc, $class, 'Temporalio::Exception');

        my $ok = eval { $class->throw(message => 'sub boom'); 1 };
        T2->ok(!$ok, "$class->throw dies");
        T2->isa_ok($@, $class);
        T2->is($@->message, 'sub boom', "$class thrown message intact");
    }
});

T2->subtest('stringification walks the cause chain (T-exc-3)' => sub {
    my $baz = Temporalio::Exception->new(message => 'baz');
    my $bar = Temporalio::Exception->new(message => 'bar', cause => $baz);
    my $foo = Temporalio::Exception->new(message => 'foo', cause => $bar);

    T2->is("$foo", 'foo: caused by: bar: caused by: baz', '3-deep chain stringifies');
    T2->is("$bar", 'bar: caused by: baz', '2-deep chain stringifies');
    T2->is("$baz", 'baz', 'no cause stringifies to the message alone');
    T2->ref_is($foo->cause, $bar, 'cause accessor returns the inner exception');
});

# Spec R68 reversed the original narrow contract: any defined value is now
# accepted as a cause and stored as-is. The full contract (string dies,
# foreign objects, stringification, wire encoding) is pinned in
# t/unit/exception_cause_chaining.t; this keeps the acceptance visible here.
T2->subtest('any defined value is accepted as a cause (R68)' => sub {
    my $string_cause = Temporalio::Exception->new(
        message => 'x', cause => 'plain scalar',
    );
    T2->is($string_cause->cause, 'plain scalar',
        'a plain-scalar cause is accepted and stored as-is');

    my $foreign = bless {}, 'Some::Other::Thing';
    my $object_cause = Temporalio::Exception->new(
        message => 'x', cause => $foreign,
    );
    T2->ref_is($object_cause->cause, $foreign,
        'a non-exception object cause is accepted and stored as-is');
});

T2->subtest('stack_trace is populated via Devel::StackTrace' => sub {
    my $exc = Temporalio::Exception->new(message => 'x');
    T2->isa_ok($exc->stack_trace, 'Devel::StackTrace');
    my $frame = $exc->stack_trace->frame(0);
    T2->ok($frame, 'trace has at least one frame');
    T2->like($frame->filename, qr/exception\.t/, 'trace starts at the caller, not inside the class');

    my $thrown_ok = eval { Temporalio::Exception::Runtime->throw(message => 'y'); 1 };
    T2->ok(!$thrown_ok, 'throw dies');
    T2->like($@->stack_trace->frame(0)->filename, qr/exception\.t/, 'throw traces start at the caller too');

    my $custom = Devel::StackTrace->new;
    my $explicit = Temporalio::Exception->new(message => 'x', stack_trace => $custom);
    T2->ref_is($explicit->stack_trace, $custom, 'an explicit stack_trace is kept as-is');
});

# --- Spec section 6.2: the full concrete-subclass hierarchy -----------------

# Every class in spec section 6.2 with its listed fields and a sample value per
# field. Each entry: [parent class, { field => sample }]. The parent defaults
# to Temporalio::Exception; Rpc* and *NotFound override it (T-exc-4 shape).
my %SPEC_SUBCLASSES = (
    'Temporalio::Exception::Application' => [undef, {
        type          => 'X',
        non_retryable => 1,
        details       => ['a', 1],
        category      => 'benign',
    }],
    'Temporalio::Exception::Cancelled' => [undef, { details => ['d'] }],
    'Temporalio::Exception::Timeout'   => [undef, {
        timeout_type           => 'start_to_close',
        last_heartbeat_details => [42],
    }],
    'Temporalio::Exception::Terminated' => [undef, { reason => 'because' }],
    'Temporalio::Exception::Server'     => [undef, {
        non_retryable => 1,
        details       => ['d'],
    }],
    'Temporalio::Exception::Activity' => [undef, {
        activity_id        => 'a1',
        activity_type      => 'MyActivity',
        attempt            => 3,
        identity           => 'worker@host',
        retry_state        => 'in_progress',
        started_event_id   => 7,
        scheduled_event_id => 6,
    }],
    'Temporalio::Exception::ChildWorkflow' => [undef, {
        namespace          => 'ns',
        workflow_id        => 'wf-1',
        run_id             => 'run-1',
        workflow_type      => 'MyWorkflow',
        retry_state        => 'timeout',
        initiated_event_id => 1,
        started_event_id   => 2,
    }],
    'Temporalio::Exception::NexusHandler' => [undef, {
        type           => 'BAD_REQUEST',
        retry_behavior => 1,
    }],
    'Temporalio::Exception::NexusOperation' => [undef, {
        scheduled_event_id => 5,
        endpoint           => 'ep',
        service            => 'svc',
        operation          => 'op',
        operation_token    => 'tok',
    }],
    'Temporalio::Exception::ResetWorkflow' => [undef, {
        last_heartbeat_details => ['h'],
    }],
    'Temporalio::Exception::WorkflowAlreadyStarted' => [undef, {
        workflow_id   => 'wf-1',
        workflow_type => 'MyWorkflow',
        run_id        => 'run-1',
    }],
    'Temporalio::Exception::RpcError' => [undef, {
        status_code => 5,
        status_name => 'NOT_FOUND',
        details     => { code => 5 },
    }],
    'Temporalio::Exception::RpcTimeout' =>
        ['Temporalio::Exception::RpcError', {}],
    'Temporalio::Exception::RpcUnauthenticated' =>
        ['Temporalio::Exception::RpcError', {}],
    'Temporalio::Exception::RpcPermissionDenied' =>
        ['Temporalio::Exception::RpcError', {}],
    'Temporalio::Exception::RpcResourceExhausted' =>
        ['Temporalio::Exception::RpcError', {}],
    'Temporalio::Exception::Bridge'   => [undef, {}],
    'Temporalio::Exception::Runtime'  => [undef, {}],
    'Temporalio::Exception::Argument' => [undef, {}],
    'Temporalio::Exception::NotFound' => [undef, {}],
    'Temporalio::Exception::WorkflowNotFound' =>
        ['Temporalio::Exception::NotFound', {}],
    'Temporalio::Exception::ActivityNotFound' =>
        ['Temporalio::Exception::NotFound', {}],
    'Temporalio::Exception::NamespaceNotFound' =>
        ['Temporalio::Exception::NotFound', {}],
    'Temporalio::Exception::DataConverter' => [undef, {}],
    'Temporalio::Exception::Heartbeat'     => [undef, {}],
    'Temporalio::Exception::QueryRejected' => [undef, {
        status => 'WORKFLOW_EXECUTION_STATUS_COMPLETED',
    }],
    'Temporalio::Exception::WorkflowContinuedAsNew' => [undef, {
        new_run_id => 'run-2',
    }],
    'Temporalio::Exception::Workflow::NoRunner' => [undef, {}],
);

T2->subtest('every spec 6.2 class exists with its listed fields (table-driven)' => sub {
    for my $class (sort keys %SPEC_SUBCLASSES) {
        my ($parent, $fields) = @{ $SPEC_SUBCLASSES{$class} };
        (my $file = "$class.pm") =~ s{::}{/}g;
        my $loaded = eval { require $file; 1 };
        T2->ok($loaded, "$class loads") or do { T2->diag($@); next };

        my $exc = $class->new(message => 'm', %$fields);
        T2->isa_ok($exc, $class, $parent // (), 'Temporalio::Exception');
        T2->is($exc->message, 'm', "$class inherits message");
        for my $field (sort keys %$fields) {
            T2->is($exc->$field, $fields->{$field}, "$class ->$field round-trips");
        }
    }
});

T2->subtest('Application accessors and defaults (T-exc-1)' => sub {
    require Temporalio::Exception::Application;
    my $exc = Temporalio::Exception::Application->new(
        message       => 'oops',
        type          => 'X',
        non_retryable => 1,
    );
    T2->is($exc->type, 'X', 'type accessor');
    T2->is($exc->non_retryable, 1, 'non_retryable accessor');
    T2->is($exc->category, 'application', "category defaults to 'application'");
    T2->is($exc->details, undef, 'details defaults to undef');

    my $plain = Temporalio::Exception::Application->new(message => 'm');
    T2->ok(!$plain->non_retryable, 'non_retryable defaults to false');
    T2->is($plain->type, undef, 'type defaults to undef');
});

T2->subtest('RpcTimeout isa RpcError (T-exc-4)' => sub {
    require Temporalio::Exception::RpcTimeout;
    T2->ok(Temporalio::Exception::RpcTimeout->isa('Temporalio::Exception::RpcError'),
        'RpcTimeout isa RpcError');
    my $exc = Temporalio::Exception::RpcTimeout->new(
        message     => 'deadline exceeded',
        status_code => 4,
        status_name => 'DEADLINE_EXCEEDED',
    );
    T2->is($exc->status_code, 4, 'status_code inherited from RpcError');
    T2->is($exc->status_name, 'DEADLINE_EXCEEDED', 'status_name inherited');
});

T2->subtest('WorkflowFailure requires a cause' => sub {
    require Temporalio::Exception::WorkflowFailure;
    my $inner = Temporalio::Exception->new(message => 'root');
    my $exc = Temporalio::Exception::WorkflowFailure->new(
        message => 'workflow failed',
        cause   => $inner,
    );
    T2->isa_ok($exc, 'Temporalio::Exception::WorkflowFailure', 'Temporalio::Exception');
    T2->ref_is($exc->cause, $inner, 'cause is the wrapped exception');

    my $ok = eval {
        Temporalio::Exception::WorkflowFailure->new(message => 'no cause');
        1;
    };
    T2->ok(!$ok, 'constructing without a cause dies');
    T2->isa_ok($@, 'Temporalio::Exception::Argument');
    T2->like($@->message, qr/cause/, 'diagnostic names the cause field');
});

T2->done_testing;
