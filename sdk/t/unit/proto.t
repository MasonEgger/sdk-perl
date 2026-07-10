# ABOUTME: Tests Temporalio::Core::Proto (spec section 4.6): vendored-proto load,
# ABOUTME: generated-class round-trips, and full-name -> Perl-class resolution.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

# T-proto-1: load succeeds and is idempotent.
T2->subtest('load succeeds and is idempotent (T-proto-1)' => sub {
    my $ok = eval { require Temporalio::Core::Proto; 1 };
    T2->ok($ok, 'Temporalio::Core::Proto loads') or T2->diag($@);

    $ok = eval { Temporalio::Core::Proto->load; 1 };
    T2->ok($ok, 'load succeeds') or T2->diag($@);

    $ok = eval { Temporalio::Core::Proto->load; 1 };
    T2->ok($ok, 'second load is a no-op, not an error') or T2->diag($@);

    T2->ok(
        Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation->can('new'),
        'a generated class is installed after load',
    );
});

# T-proto-2: WorkflowActivation round-trip — coresdk tree, WKT Timestamp,
# repeated nested messages, oneof job variants.
T2->subtest('WorkflowActivation round-trips (T-proto-2)' => sub {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    my $act   = $class->new({
        run_id         => 'run-1',
        timestamp      => { seconds => 1_718_000_000, nanos => 42 },
        is_replaying   => 1,
        history_length => 100,
        jobs           => [
            { fire_timer       => { seq => 7 } },
            { resolve_activity => { seq => 9 } },
        ],
    });

    my $bytes = $act->encode;
    T2->ok(length $bytes, 'encode produced wire bytes');

    my $got = $class->decode($bytes);
    T2->isa_ok($got, $class);
    T2->is($got->run_id,         'run-1', 'run_id survives');
    T2->is($got->is_replaying,   1,       'is_replaying survives');
    T2->is($got->history_length, 100,     'history_length survives');
    T2->is(
        $got->timestamp->to_hashref,
        { seconds => 1_718_000_000, nanos => 42 },
        'WKT Timestamp survives',
    );
    T2->is(scalar $got->jobs->@*, 2, 'both jobs survive');
    T2->is($got->jobs->[0]->fire_timer->seq, 7, 'oneof job variant 1 survives');
    T2->is($got->jobs->[1]->resolve_activity->seq, 9, 'oneof job variant 2 survives');
    T2->is($got->jobs->[0]->which_variant, 'fire_timer', 'oneof discriminator reports');
});

# T-proto-3: StartWorkflowExecutionRequest round-trip — the deepest realistic
# import chain in the api_upstream tree (regression guard for re-vendors).
T2->subtest('StartWorkflowExecutionRequest round-trips (T-proto-3)' => sub {
    my $class = 'Temporalio::Proto::Api::Workflowservice::V1::StartWorkflowExecutionRequest';
    my $req   = $class->new({
        namespace     => 'default',
        workflow_id   => 'wf-1',
        request_id    => 'req-1',
        workflow_type => { name => 'MyWorkflow' },
        task_queue    => { name => 'tq' },
        input         => {
            payloads => [
                {
                    metadata => { encoding => 'json/plain' },
                    data     => '"hello"',
                },
            ],
        },
        workflow_execution_timeout => { seconds => 60 },
    });

    my $got = $class->decode($req->encode);
    T2->isa_ok($got, $class);
    T2->is($got->namespace,           'default',    'namespace survives');
    T2->is($got->workflow_id,         'wf-1',       'workflow_id survives');
    T2->is($got->workflow_type->name, 'MyWorkflow', 'nested WorkflowType survives');
    T2->is($got->task_queue->name,    'tq',         'nested TaskQueue survives');
    T2->is($got->workflow_execution_timeout->seconds, 60, 'WKT Duration survives');

    my $payload = $got->input->payloads->[0];
    T2->is($payload->metadata, { encoding => 'json/plain' }, 'payload metadata map survives');
    T2->is($payload->data, '"hello"', 'payload data bytes survive');
});

# T-proto-4: Failure with a 3-deep cause chain round-trips.
T2->subtest('Failure 3-deep cause chain round-trips (T-proto-4)' => sub {
    my $class = 'Temporalio::Proto::Api::Failure::V1::Failure';
    my $fail  = $class->new({
        message => 'outer',
        source  => 'PerlSDK',
        cause   => {
            message => 'middle',
            cause   => {
                message                  => 'inner',
                stack_trace              => "at line 1\n",
                application_failure_info => {
                    type          => 'SomeError',
                    non_retryable => 1,
                },
            },
        },
    });

    my $got = $class->decode($fail->encode);
    T2->isa_ok($got, $class);
    T2->is($got->message, 'outer', 'outer message survives');
    T2->is($got->source,  'PerlSDK', 'source survives');

    my $mid = $got->cause;
    T2->isa_ok($mid, $class);
    T2->is($mid->message, 'middle', 'middle message survives');

    my $inner = $mid->cause;
    T2->isa_ok($inner, $class);
    T2->is($inner->message,     'inner',        'inner message survives');
    T2->is($inner->stack_trace, "at line 1\n",  'inner stack_trace survives');
    T2->is($inner->application_failure_info->type, 'SomeError',
        'oneof failure_info member survives');
    T2->is($inner->application_failure_info->non_retryable, 1,
        'non_retryable flag survives');
    T2->is($inner->cause, undef, 'chain terminates');
});

# T-proto-5: full-name -> generated-class resolution.
T2->subtest('resolve maps protobuf full names to Perl classes (T-proto-5)' => sub {
    T2->is(
        Temporalio::Core::Proto::resolve('temporal.api.failure.v1.Failure'),
        'Temporalio::Proto::Api::Failure::V1::Failure',
        'api_upstream full name resolves',
    );
    T2->is(
        Temporalio::Core::Proto::resolve('coresdk.workflow_activation.WorkflowActivation'),
        'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation',
        'coresdk full name resolves',
    );

    my $ok = eval { Temporalio::Core::Proto::resolve('no.such.Message'); 1 };
    T2->ok(!$ok, 'unknown full name dies');
    T2->like($@, qr/no\.such\.Message/, 'diagnostic names the unknown full name');
});

T2->done_testing;
