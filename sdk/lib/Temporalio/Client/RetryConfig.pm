# ABOUTME: Client RPC retry configuration (spec section 7.2): MUST-match
# ABOUTME: sdk-core defaults in seconds, plus the ClientRetryOptions builder.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::FFI ();

class Temporalio::Client::RetryConfig {
    # Defaults are the spec section 7.2 MUST-match table, verified against
    # sdk-python service.py RetryConfig (100ms/0.2/1.5/5000ms/10000ms/10)
    # and sdk-ruby client/connection.rb RPCRetryOptions. All durations are
    # seconds Perl-side; to_ffi converts to the bridge's milliseconds.
    field $initial_interval     :param = 0.1;
    field $randomization_factor :param = 0.2;
    field $multiplier           :param = 1.5;
    field $max_interval         :param = 5.0;
    field $max_elapsed_time     :param = 10.0;   # 0 = unlimited
    field $max_retries          :param = 10;

    method initial_interval     { $initial_interval }
    method randomization_factor { $randomization_factor }
    method multiplier           { $multiplier }
    method max_interval         { $max_interval }
    method max_elapsed_time     { $max_elapsed_time }
    method max_retries          { $max_retries }

    # Builds the TemporalCoreClientRetryOptions record (no backing buffers;
    # @$keep is accepted for builder-signature uniformity). The bridge maps
    # max_elapsed_time_millis 0 to None, i.e. unlimited.
    method to_ffi ($keep = undef) {
        return Temporalio::Core::FFI::ClientRetryOptions->new(
            initial_interval_millis => int($initial_interval * 1000),
            randomization_factor    => $randomization_factor,
            multiplier              => $multiplier,
            max_interval_millis     => int($max_interval * 1000),
            max_elapsed_time_millis => int(($max_elapsed_time // 0) * 1000),
            max_retries             => $max_retries,
        );
    }
}

1;

__END__

=head1 NAME

Temporalio::Client::RetryConfig - retry configuration for client RPC calls

=head1 SYNOPSIS

    use Temporalio::Client::RetryConfig;

    my $retry = Temporalio::Client::RetryConfig->new(
        initial_interval     => 0.1,    # seconds (defaults shown)
        randomization_factor => 0.2,
        multiplier           => 1.5,
        max_interval         => 5.0,
        max_elapsed_time     => 10.0,   # 0 = unlimited
        max_retries          => 10,
    );

=head1 DESCRIPTION

Retry options sdk-core applies to retryable client RPC failures (spec
section 7.2). The defaults MUST match the cross-SDK client retry defaults
and are verified against the reference SDKs in F<t/unit/client_config.t>.
Durations are seconds; C<to_ffi> builds the
C<TemporalCoreClientRetryOptions> record in milliseconds. Retries happen
inside sdk-core, never in the Perl layer (spec section 7.5).

=cut
