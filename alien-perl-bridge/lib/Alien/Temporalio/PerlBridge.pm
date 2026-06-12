package Alien::Temporalio::PerlBridge;
# ABOUTME: Alien distribution exposing the in-tree temporalio-perl-bridge Rust
# ABOUTME: callback-shim cdylib and its cbindgen-generated C header.

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

Alien::Temporalio::PerlBridge - Build and locate the temporalio-perl-bridge callback shim

=head1 SYNOPSIS

    use Alien::Temporalio::PerlBridge;

    my @libs    = Alien::Temporalio::PerlBridge->dynamic_libs;
    my $headers = Alien::Temporalio::PerlBridge->include_dir;
    my $version = Alien::Temporalio::PerlBridge->version;  # SDK-locked

=head1 DESCRIPTION

Compiles the in-tree C<ext/temporalio-perl-bridge> Rust crate (the callback
trampoline shim that keeps sdk-core's Tokio threads away from the Perl
interpreter) into C<libtemporalio_perl_bridge> and exposes the shared library
and its cbindgen-generated header via the L<Alien::Base> API.

Building requires L<Alien::Temporalio::Core> (for the upstream
C<temporal-sdk-core-c-bridge.h>) and a Rust toolchain on C<PATH>.

The crate is located by walking upward from the alienfile; set
C<ALIEN_TEMPORALIO_PERL_BRIDGE_EXT_PATH> to point at the crate directory for
out-of-tree layouts.

=head1 METHODS

=head2 include_dir

Returns the directory containing C<temporalio-perl-bridge.h>.

=head1 SEE ALSO

L<Alien::Temporalio::Core>, L<Alien::Base>, L<alienfile>

=cut
