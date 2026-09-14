# ABOUTME: Tests Temporalio::Core::Proto (spec section 4.6): vendored-proto load,
# ABOUTME: generated-class round-trips, and full-name -> Perl-class resolution.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();

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

# T-proto-6: duration_from_seconds/seconds_from_duration (I14 shared pair):
# whole seconds, fractional split with the +0.5 rounding, zero, undef
# passthrough on the read side, and a round-trip.
T2->subtest('duration_from_seconds/seconds_from_duration round-trip (T-proto-6)' => sub {
    T2->is(
        Temporalio::Core::Proto::seconds_from_duration(undef),
        undef,
        'seconds_from_duration(undef) passes through as undef',
    );

    my $whole = Temporalio::Core::Proto::duration_from_seconds(5);
    T2->is($whole->seconds, 5, 'whole seconds -> Duration.seconds');
    T2->is($whole->nanos,   0, 'whole seconds -> Duration.nanos is 0');

    my $frac = Temporalio::Core::Proto::duration_from_seconds(1.5);
    T2->is($frac->seconds, 1,           'fractional seconds -> Duration.seconds truncates');
    T2->is($frac->nanos,   500_000_000, 'fractional seconds -> Duration.nanos, +0.5 rounded');

    my $zero = Temporalio::Core::Proto::duration_from_seconds(0);
    T2->is($zero->seconds, 0, 'zero seconds -> Duration.seconds 0');
    T2->is($zero->nanos,   0, 'zero seconds -> Duration.nanos 0');

    T2->is(
        Temporalio::Core::Proto::seconds_from_duration($whole),
        5,
        'whole-seconds Duration round-trips back to 5',
    );
    T2->is(
        Temporalio::Core::Proto::seconds_from_duration($frac),
        1.5,
        'fractional Duration round-trips back to 1.5',
    );
    T2->is(
        Temporalio::Core::Proto::seconds_from_duration($zero),
        0,
        'zero Duration round-trips back to 0 (not undef; unset-vs-zero is a call-site concern)',
    );
});

# T-proto-6 (continued): sign-aware rounding, the carry at one billion nanos,
# string input, and the non-finite/out-of-range guard. The reference contract
# is protobuf's Duration._NormalizeDuration and _CheckDurationValid
# (google/protobuf/internal/well_known_types.py:451-482): seconds and nanos
# carry the SAME sign, nanos stay within [-999999999, 999999999], and seconds
# stay within [-315576000000, 315576000000].
T2->subtest('duration_from_seconds rounds sign-aware and carries (T-proto-6)' => sub {
    my $neg = Temporalio::Core::Proto::duration_from_seconds(-1.5);
    T2->is($neg->seconds, -1, 'negative fractional seconds -> Duration.seconds -1');
    T2->is($neg->nanos, -500_000_000,
        'negative fraction rounds to exactly -500000000 nanos, not -499999999');
    T2->is(
        Temporalio::Core::Proto::seconds_from_duration($neg),
        -1.5,
        '-1.5 round-trips back exactly',
    );

    my $sub = Temporalio::Core::Proto::duration_from_seconds(-0.25);
    T2->is($sub->seconds, 0, 'sub-second negative -> Duration.seconds 0');
    T2->is($sub->nanos, -250_000_000, 'sub-second negative -> nanos -250000000');
    T2->is(
        Temporalio::Core::Proto::seconds_from_duration($sub),
        -0.25,
        '-0.25 round-trips back exactly',
    );

    # Within half a nanosecond of the next second: the rounded nanos reach
    # one billion, which is outside the proto-legal range, so they carry.
    my $carry = Temporalio::Core::Proto::duration_from_seconds(0.9999999999);
    T2->is($carry->seconds, 1, 'nanos at one billion carry into seconds');
    T2->is($carry->nanos, 0, 'nanos after the carry are 0, never 1000000000');
    T2->is(
        Temporalio::Core::Proto::seconds_from_duration($carry),
        1,
        'the carried Duration reads back as 1 second',
    );

    my $carry2 = Temporalio::Core::Proto::duration_from_seconds(2.9999999996);
    T2->is($carry2->seconds, 3, 'carry adds to a non-zero whole part');
    T2->is($carry2->nanos, 0, 'carry leaves 0 nanos');

    my $str = Temporalio::Core::Proto::duration_from_seconds('1.5');
    T2->is($str->seconds, 1, 'numeric string input -> Duration.seconds');
    T2->is($str->nanos, 500_000_000, 'numeric string input -> Duration.nanos');

    # Every nanos value stays proto-legal and sign-matched with its seconds.
    for my $secs (-1.5, -0.25, 0.9999999999, 2.9999999996, 1.5, 0, -0.0000000004) {
        my $d = Temporalio::Core::Proto::duration_from_seconds($secs);
        T2->ok(
            $d->nanos > -1_000_000_000 && $d->nanos < 1_000_000_000,
            "nanos for $secs stay within the proto-legal range",
        );
        T2->ok(
            !(($d->nanos < 0 && $d->seconds > 0)
                || ($d->nanos > 0 && $d->seconds < 0)),
            "seconds and nanos for $secs share a sign",
        );
    }
});

# T-proto-6 (continued): non-numeric, NaN, Inf, and beyond-range seconds are
# caller errors, not silently mangled int64 fields. The string cases matter
# because Perl numifies them quietly: without a looks_like_number guard 'abc'
# and '' encode as a zero Duration and '3abc' as 3 seconds, each with nothing
# louder than a numeric warning.
T2->subtest('duration_from_seconds rejects non-numeric and non-finite input (T-proto-6)' => sub {
    my $inf = 9**9**9;
    # Each row carries the diagnostic it must produce, so a guard that fires
    # for the wrong reason (a range rejection swallowing a NaN, say) fails
    # here rather than passing on the exception class alone.
    my $not_finite = qr/^duration seconds must be a finite number/;
    my $out_of_range = qr/outside the google\.protobuf\.Duration range/;
    my %bad = (
        'NaN'                   => [ $inf - $inf,        $not_finite ],
        '+Inf'                  => [ $inf,               $not_finite ],
        '-Inf'                  => [ -$inf,              $not_finite ],
        'non-numeric string'    => [ 'abc',              $not_finite ],
        'empty string'          => [ '',                 $not_finite ],
        'numeric-prefix string' => [ '3abc',             $not_finite ],
        'beyond Duration max'   => [ 315_576_000_001,    $out_of_range ],
        'beyond Duration min'   => [ -315_576_000_001,   $out_of_range ],
    );
    for my $label (sort keys %bad) {
        my ($value, $expected) = @{ $bad{$label} };
        my $ok = eval {
            Temporalio::Core::Proto::duration_from_seconds($value); 1 };
        my $err = $@;
        T2->ok(!$ok, "$label input dies rather than producing a bad Duration");
        T2->ok(
            Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::Argument'),
            "$label input raises Temporalio::Exception::Argument",
        ) or next;
        T2->like($err->message, $expected,
            "$label input is rejected for the right reason");
    }

    # The range bounds themselves are accepted (protobuf's check is inclusive).
    my $max = Temporalio::Core::Proto::duration_from_seconds(315_576_000_000);
    T2->is($max->seconds, 315_576_000_000, 'the maximum Duration seconds is accepted');
    my $min = Temporalio::Core::Proto::duration_from_seconds(-315_576_000_000);
    T2->is($min->seconds, -315_576_000_000, 'the minimum Duration seconds is accepted');
});

T2->done_testing;
