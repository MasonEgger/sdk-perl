# ABOUTME: Versioning-behavior override for a single workflow execution (spec
# ABOUTME: R37), mapping to temporal.api.workflow.v1.VersioningOverride like
# ABOUTME: sdk-python common.py Pinned/AutoUpgradeVersioningOverride.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();

class Temporalio::Common::VersioningOverride {
    # kind: 'pinned' | 'auto_upgrade'. Use the pinned()/auto_upgrade()
    # constructors below rather than new() directly.
    field $kind    :param;
    field $version :param = undef;    # Temporalio::Worker::DeploymentVersion

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => "invalid VersioningOverride kind '$kind' "
                     . "(use ->pinned or ->auto_upgrade)")
            unless $kind eq 'pinned' || $kind eq 'auto_upgrade';
        if ($kind eq 'pinned') {
            Temporalio::Exception::Argument->throw(
                message => 'VersioningOverride->pinned requires a '
                         . 'Temporalio::Worker::DeploymentVersion')
                unless Scalar::Util::blessed($version)
                    && $version->isa('Temporalio::Worker::DeploymentVersion');
        }
    }

    method kind    { $kind }
    method version { $version }

    # Pin the workflow to a specific worker deployment version.
    sub pinned ($class, $deployment_version) {
        return $class->new(kind => 'pinned', version => $deployment_version);
    }

    # Auto-upgrade the workflow to the current deployment version on the next
    # workflow task.
    sub auto_upgrade ($class) {
        return $class->new(kind => 'auto_upgrade');
    }

    # temporal.api.workflow.v1.VersioningOverride, MUST-match sdk-python
    # common.py Pinned/AutoUpgradeVersioningOverride._to_proto: the current
    # `override` oneof arm PLUS the deprecated behavior/pinned_version fields
    # for backward compatibility with older servers.
    method to_proto {
        my $Override = Temporalio::Core::Proto::resolve(
            'temporal.api.workflow.v1.VersioningOverride');
        if ($kind eq 'auto_upgrade') {
            return $Override->new({
                behavior     => 2,    # VERSIONING_BEHAVIOR_AUTO_UPGRADE
                auto_upgrade => 1,
            });
        }
        my $Pinned = Temporalio::Core::Proto::resolve(
            'temporal.api.workflow.v1.VersioningOverride.PinnedOverride');
        my $Version = Temporalio::Core::Proto::resolve(
            'temporal.api.deployment.v1.WorkerDeploymentVersion');
        return $Override->new({
            behavior       => 1,    # VERSIONING_BEHAVIOR_PINNED
            pinned_version => $version->to_canonical_string,
            pinned         => $Pinned->new({
                behavior => 1,      # PINNED_OVERRIDE_BEHAVIOR_PINNED
                version  => $Version->new({
                    deployment_name => $version->deployment_name,
                    build_id        => $version->build_id,
                }),
            }),
        });
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Common::VersioningOverride - per-execution worker-versioning override

=head1 SYNOPSIS

    use Temporalio::Common::VersioningOverride ();
    use Temporalio::Worker::DeploymentVersion ();

    my $pinned = Temporalio::Common::VersioningOverride->pinned(
        Temporalio::Worker::DeploymentVersion->new(
            deployment_name => 'my-deploy',
            build_id        => 'abc123',
        ));
    my $auto = Temporalio::Common::VersioningOverride->auto_upgrade;

    $client->start_workflow('MyWorkflow', [],
        id => 'wf', task_queue => 'q',
        versioning_override => $pinned);

=head1 DESCRIPTION

An override of the worker-versioning behavior for one workflow execution
(spec R37), passed as the C<versioning_override> option to C<start_workflow>
or C<signal_with_start_workflow>. C<to_proto> builds the
C<temporal.api.workflow.v1.VersioningOverride> message the same way
sdk-python's C<PinnedVersioningOverride>/C<AutoUpgradeVersioningOverride>
do: the current C<override> oneof arm plus the deprecated
C<behavior>/C<pinned_version> fields for backward compatibility.

=head1 CONSTRUCTORS

=head2 pinned

    Temporalio::Common::VersioningOverride->pinned($deployment_version);

Class method. Pins the workflow to the given
L<Temporalio::Worker::DeploymentVersion>; anything else raises
L<Temporalio::Exception::Argument>.

=head2 auto_upgrade

    Temporalio::Common::VersioningOverride->auto_upgrade;

Class method. The workflow auto-upgrades to the current deployment version
on its next workflow task.

=head2 new

    my $obj = Temporalio::Common::VersioningOverride->new(
        kind    => ...,
        version => ...,
    );

Constructs a Temporalio::Common::VersioningOverride. Prefer the C<pinned> /
C<auto_upgrade> constructors. Named parameters:

=over 4

=item C<kind>

(required) C<'pinned'> or C<'auto_upgrade'>.

=item C<version>

(optional, default C<undef>) the L<Temporalio::Worker::DeploymentVersion>,
required when C<kind> is C<'pinned'>.

=back

=head1 METHODS

=head2 kind

Accessor returning C<'pinned'> or C<'auto_upgrade'>.

=head2 version

Accessor returning the L<Temporalio::Worker::DeploymentVersion> (undef for
auto-upgrade overrides).

=head2 to_proto

Builds and returns the C<temporal.api.workflow.v1.VersioningOverride> proto
message for this override.

=cut
