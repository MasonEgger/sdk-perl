# ABOUTME: Distribution entry point for the Temporalio Perl SDK.
# ABOUTME: Declares the package and version; functionality lives in submodules.
package Temporalio::SDK;

use v5.38;
use warnings;

our $VERSION = '0.2.0';

1;

__END__

=head1 NAME

Temporalio::SDK - Temporal SDK for Perl

=head1 DESCRIPTION

Entry point for the Temporalio-SDK distribution. Drives the Rust
C<sdk-core> through its C ABI via L<FFI::Platypus>. See the
distribution documentation for the client, worker, workflow, and
activity APIs.

=cut
