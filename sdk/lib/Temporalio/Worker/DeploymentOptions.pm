# ABOUTME: Worker deployment options (spec §29.1): the DeploymentVersion plus
# ABOUTME: use_worker_versioning and a default_versioning_behavior string mapped
# ABOUTME: to the proto VersioningBehavior enum. Mirrors sdk-ruby DeploymentOptions.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();

class Temporalio::Worker::DeploymentOptions {
    field $version                     :param = undef;
    field $use_worker_versioning       :param = 0;
    field $default_versioning_behavior :param = 'unspecified';

    # default_versioning_behavior string -> proto temporal.api.enums.v1
    # .VersioningBehavior value (verified against the proto descriptor and
    # sdk-ruby/common_enums.rb): unspecified=0, pinned=1, auto_upgrade=2.
    my %BEHAVIOR = (
        unspecified  => 0,
        pinned       => 1,
        auto_upgrade => 2,
    );

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => 'DeploymentOptions requires a version')
            unless defined $version;
        Temporalio::Exception::Argument->throw(
            message => "DeploymentOptions version must be a "
                . "Temporalio::Worker::DeploymentVersion")
            unless ref $version
                && $version->isa('Temporalio::Worker::DeploymentVersion');

        Temporalio::Exception::Argument->throw(
            message => "unknown default_versioning_behavior "
                . "'$default_versioning_behavior' (expected one of: "
                . join(', ', sort keys %BEHAVIOR) . ')')
            unless exists $BEHAVIOR{$default_versioning_behavior};

        # A non-unspecified default behavior is meaningless without versioning
        # on (spec §29.1).
        if ($default_versioning_behavior ne 'unspecified'
            && !$use_worker_versioning) {
            Temporalio::Exception::Argument->throw(
                message => "default_versioning_behavior must be 'unspecified' "
                    . "unless use_worker_versioning is enabled");
        }
    }

    method version                     { $version }
    method use_worker_versioning       { $use_worker_versioning ? 1 : 0 }
    method default_versioning_behavior { $default_versioning_behavior }

    # The proto enum value for default_versioning_behavior.
    method default_versioning_behavior_value {
        return $BEHAVIOR{$default_versioning_behavior};
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::DeploymentOptions - worker deployment versioning options

=head1 SYNOPSIS

    use Temporalio::Worker::DeploymentVersion ();
    use Temporalio::Worker::DeploymentOptions ();

    my $opts = Temporalio::Worker::DeploymentOptions->new(
        version => Temporalio::Worker::DeploymentVersion->new(
            deployment_name => 'my-deploy', build_id => 'abc123'),
        use_worker_versioning       => 1,
        default_versioning_behavior => 'pinned',
    );

=head1 DESCRIPTION

Configures the deployment-based worker versioning strategy (spec section 29.1):
a L<Temporalio::Worker::DeploymentVersion>, a C<use_worker_versioning> flag, and
a C<default_versioning_behavior> string (C<unspecified>, C<pinned>, or
C<auto_upgrade>) mapped to the proto C<VersioningBehavior> enum. A
non-C<unspecified> behavior requires C<use_worker_versioning> to be on.

This is the supported replacement for the deprecated legacy build-id
compatibility APIs, which the client deliberately does not port (spec R97,
parity audit client finding 5); see "OMITTED LEGACY BUILD-ID APIS" in
L<Temporalio::Client>.

=head1 METHODS

=head2 version

The L<Temporalio::Worker::DeploymentVersion>.

=head2 use_worker_versioning

The versioning flag, 0 or 1.

=head2 default_versioning_behavior

The behavior string.

=head2 default_versioning_behavior_value

The proto enum value (0/1/2) for the behavior string.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Worker::DeploymentOptions. C<version> is required;
C<use_worker_versioning> defaults to 0 and C<default_versioning_behavior> to
C<unspecified>.

=cut
