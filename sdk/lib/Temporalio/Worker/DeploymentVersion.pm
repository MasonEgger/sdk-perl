# ABOUTME: Worker deployment version (spec §29.1): a (deployment_name, build_id)
# ABOUTME: pair with a canonical "<name>.<build_id>" string round-trip, mirroring
# ABOUTME: sdk-ruby WorkerDeploymentVersion.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();

class Temporalio::Worker::DeploymentVersion {
    field $deployment_name :param;
    field $build_id        :param;

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => 'DeploymentVersion requires a deployment_name')
            unless defined $deployment_name && length $deployment_name;
        Temporalio::Exception::Argument->throw(
            message => 'DeploymentVersion requires a build_id')
            unless defined $build_id && length $build_id;
    }

    method deployment_name { $deployment_name }
    method build_id        { $build_id }

    # "<deployment_name>.<build_id>" (sdk-ruby worker_deployment_version.rb).
    method to_canonical_string {
        return "$deployment_name.$build_id";
    }

    # Parse "<deployment_name>.<build_id>"; split on the FIRST dot so the
    # build_id may itself contain dots (the deployment name may not). A string
    # with no dot is malformed → Argument.
    sub from_canonical_string ($class, $canonical) {
        my $at = index $canonical // '', '.';
        if (!defined $canonical || $at < 0) {
            Temporalio::Exception::Argument->throw(
                message => "Cannot parse version string: "
                    . (defined $canonical ? $canonical : '(undef)')
                    . ", must be in format <deployment_name>.<build_id>");
        }
        return $class->new(
            deployment_name => substr($canonical, 0, $at),
            build_id        => substr($canonical, $at + 1),
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::DeploymentVersion - a worker deployment version

=head1 SYNOPSIS

    use Temporalio::Worker::DeploymentVersion ();

    my $version = Temporalio::Worker::DeploymentVersion->new(
        deployment_name => 'my-deploy',
        build_id        => 'abc123',
    );
    $version->to_canonical_string;   # "my-deploy.abc123"

    my $parsed = Temporalio::Worker::DeploymentVersion
        ->from_canonical_string('my-deploy.abc123');

=head1 DESCRIPTION

A C<(deployment_name, build_id)> pair identifying a worker deployment version
(spec section 29.1). The canonical string form is
C<< <deployment_name>.<build_id> >>; parsing splits on the first dot so the
build id may contain dots.

=head1 METHODS

=head2 deployment_name

The deployment name.

=head2 build_id

The build identifier.

=head2 to_canonical_string

The C<< <deployment_name>.<build_id> >> string.

=head2 from_canonical_string

Class method. Parses a canonical string into a
L<Temporalio::Worker::DeploymentVersion>, raising
L<Temporalio::Exception::Argument> when the string lacks a dot.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Worker::DeploymentVersion from C<deployment_name> and
C<build_id> (both required).

=cut
