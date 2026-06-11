package Alien::Temporalio::Core;
# ABOUTME: Alien distribution exposing the temporal-sdk-core C bridge cdylib
# ABOUTME: (libtemporalio_sdk_core_c_bridge) and its C header to downstream code.

# Classic package rather than feature 'class': Alien::Base is a traditional
# @ISA superclass, and the :isa attribute only accepts 'class'-built parents.
use strict;
use warnings;

use parent 'Alien::Base';

use File::Spec ();

our $VERSION = '0.1.0';

sub include_dir {
    my ($class) = @_;
    return File::Spec->catdir($class->dist_dir, 'include');
}

1;

__END__

=head1 NAME

Alien::Temporalio::Core - Build and locate the temporal-sdk-core C bridge library

=head1 SYNOPSIS

    use Alien::Temporalio::Core;

    my @libs    = Alien::Temporalio::Core->dynamic_libs;
    my $headers = Alien::Temporalio::Core->include_dir;
    my $version = Alien::Temporalio::Core->version;  # pinned sdk-rust release

=head1 DESCRIPTION

Compiles (or builds from a local checkout via the
C<ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH> override) the
C<libtemporalio_sdk_core_c_bridge> shared library from a pinned
C<temporalio/sdk-rust> release tag and exposes its filesystem paths via the
L<Alien::Base> API.

=head1 METHODS

=head2 include_dir

Returns the directory containing C<temporal-sdk-core-c-bridge.h>.

=head1 SEE ALSO

L<Alien::Base>, L<alienfile>

=cut
