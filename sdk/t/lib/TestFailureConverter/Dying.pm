# ABOUTME: Test-only failure converter whose to_failure dies while ARMED.
# ABOUTME: Drives spec F8 (nothing a settlement runs during evict() may escape
# ABOUTME: the teardown). Armed only around the eviction activation so the
# ABOUTME: run's accept/init path still converts normally. $CALLS counts every
# ABOUTME: entry so the test can pin that evict() made NO converter call.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Converter::Failure;

class TestFailureConverter::Dying :isa(Temporalio::Converter::Failure) {
    # Package-scoped arming flag and call counter, not fields: the test flips
    # and reads them between activations without holding a reference to the
    # converter instance the dispatcher built.
    #
    # $CALLS counts EVERY entry into to_failure, armed or not, and is bumped
    # ahead of the die. That is what lets the F8 test assert the converter was
    # never CALLED during evict(), rather than only that the die failed to
    # escape: a regression that reinstates the call but wraps it in an eval
    # would still leave the die-does-not-escape assertion green.
    method to_failure ($exception, $payload_converter) {
        $TestFailureConverter::Dying::CALLS++;
        die "dying failure converter: to_failure refused\n"
            if $TestFailureConverter::Dying::ARMED;
        return $self->SUPER::to_failure($exception, $payload_converter);
    }
}

1;
