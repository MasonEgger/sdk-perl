# ABOUTME: Builds the core/other tracing filter string for runtime logging
# ABOUTME: (spec section 4.2), matching the format the reference SDKs produce.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();

class Temporalio::Runtime::LoggingFilter {
    # Defaults match the reference SDKs (sdk-python LoggingConfig.default,
    # sdk-ruby LoggingFilterOptions): core WARN, everything else ERROR.
    field $core_level  :param = 'WARN';
    field $other_level :param = 'ERROR';

    my %valid_level = map { $_ => 1 } qw(TRACE DEBUG INFO WARN ERROR);

    ADJUST {
        for my $pair ([ core_level => $core_level ], [ other_level => $other_level ]) {
            my ($name, $value) = @$pair;
            next if defined $value && $valid_level{$value};
            Temporalio::Exception::Argument->throw(
                message => "$name must be one of TRACE, DEBUG, INFO, WARN,"
                         . " ERROR (got '" . ($value // 'undef') . "')",
            );
        }
    }

    method core_level  { $core_level }
    method other_level { $other_level }

    # The Rust tracing filter string. Format MUST match the other SDKs
    # (verified against sdk-ruby runtime.rb and sdk-python runtime.py):
    # other_level first, then each core-side target pinned to core_level.
    # The final target is this SDK's own bridge crate.
    method to_string () {
        my @targets = qw(
            temporalio_sdk_core
            temporalio_client
            temporalio_sdk
            temporalio_perl_bridge
        );
        return join ',', $other_level, map { "$_=$core_level" } @targets;
    }
}

1;

__END__

=head1 NAME

Temporalio::Runtime::LoggingFilter - core/other level pair for runtime log filtering

=head1 SYNOPSIS

    use Temporalio::Runtime::LoggingFilter;

    my $filter = Temporalio::Runtime::LoggingFilter->new(
        core_level  => 'INFO',    # Temporal core Rust crates
        other_level => 'WARN',    # every other Rust crate
    );
    say $filter->to_string;
    # WARN,temporalio_sdk_core=INFO,temporalio_client=INFO,temporalio_sdk=INFO,temporalio_perl_bridge=INFO

=head1 DESCRIPTION

Convenience builder for the Rust C<tracing> filter string passed to the core
runtime (spec section 4.2, T-rt-6). Levels must be one of C<TRACE>, C<DEBUG>,
C<INFO>, C<WARN>, or C<ERROR>; anything else raises
L<Temporalio::Exception::Argument>. Defaults (core C<WARN>, other C<ERROR>)
match the reference SDKs.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Runtime::LoggingFilter->new(
        core_level => ...,
        other_level => ...,
    );

Constructs a Temporalio::Runtime::LoggingFilter. Named parameters:

=over 4

=item C<core_level>

(optional, default C<'WARN'>)

=item C<other_level>

(optional, default C<'ERROR'>)

=back

=head1 METHODS

=head2 core_level

Accessor returning the C<core_level> value.

=head2 other_level

Accessor returning the C<other_level> value.

=head2 to_string

Returns the C<core_level,other_level> filter string consumed by sdk-core's tracing layer.

=cut
