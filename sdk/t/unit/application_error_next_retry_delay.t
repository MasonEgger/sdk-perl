# ABOUTME: Tests ApplicationError next_retry_delay: exception field round-trips
# ABOUTME: through to_failure/from_failure and lands in the proto Duration field.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Core::Proto;
use Temporalio::Converter::Failure;
use Temporalio::Converter::Payload;
use Temporalio::Exception::Application;

my $fc = Temporalio::Converter::Failure->new;
my $pc = Temporalio::Converter::Payload->default;

my $FAILURE = Temporalio::Core::Proto::resolve('temporal.api.failure.v1.Failure');

T2->subtest('next_retry_delay survives the to_failure/from_failure round-trip' => sub {
    my $exc = Temporalio::Exception::Application->new(
        message          => 'retry me later',
        type             => 'Delayed',
        next_retry_delay => 5.5,
    );
    T2->is($exc->next_retry_delay, 5.5, 'accessor returns the constructor value');

    my $failure = $fc->to_failure($exc, $pc);
    my $decoded = $FAILURE->decode($failure->encode);
    my $back    = $fc->from_failure($decoded, $pc);
    T2->isa_ok($back, 'Temporalio::Exception::Application');
    T2->is($back->next_retry_delay, 5.5, 'next_retry_delay survives the round-trip');
});

T2->subtest('on-wire ApplicationFailureInfo.next_retry_delay is a Duration' => sub {
    my $exc = Temporalio::Exception::Application->new(
        message          => 'retry me later',
        next_retry_delay => 5.5,
    );
    my $failure = $fc->to_failure($exc, $pc);
    my $info    = $failure->application_failure_info;
    my $delay   = $info->next_retry_delay;
    T2->ok(defined $delay, 'proto next_retry_delay field is set');
    T2->is($delay->seconds, 5, 'Duration seconds is the whole part');
    T2->is($delay->nanos, 500_000_000, 'Duration nanos is the fractional part');
});

T2->subtest('no next_retry_delay leaves the proto field unset' => sub {
    my $exc = Temporalio::Exception::Application->new(
        message => 'plain failure',
    );
    T2->is($exc->next_retry_delay, undef, 'accessor defaults to undef');

    my $failure = $fc->to_failure($exc, $pc);
    my $decoded = $FAILURE->decode($failure->encode);
    T2->is($decoded->application_failure_info->next_retry_delay, undef,
        'proto field absent on the wire');

    my $back = $fc->from_failure($decoded, $pc);
    T2->is($back->next_retry_delay, undef, 'reconstructed exception has undef');
});

T2->done_testing;
