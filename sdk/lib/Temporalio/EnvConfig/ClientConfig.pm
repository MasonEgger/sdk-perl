# ABOUTME: Env-config container value class (spec section 31.1): all parsed
# ABOUTME: profiles, with load and the load_client_connect_config convenience.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::EnvConfig ();
use Temporalio::EnvConfig::ClientConfigProfile ();

class Temporalio::EnvConfig::ClientConfig {
    field $profiles :param = undef;    # hashref { name => ClientConfigProfile }

    ADJUST { $profiles //= {}; }

    method profiles { $profiles }

    # load(%kwargs) — all-profiles loader (spec section 31.1). This applies no
    # env overrides to the profiles; env is consulted only for the default
    # config-file path (TEMPORAL_CONFIG_FILE). Returns a ClientConfig holding
    # every named profile.
    sub load ($class, %kw) {
        my %opts = Temporalio::EnvConfig::ClientConfigProfile::_source_to_options(
            $kw{config_source});
        my $json = Temporalio::EnvConfig::load_client_config(
            %opts,
            config_file_strict => $kw{config_file_strict},
            env_vars           => $kw{override_env_vars},
        );
        my %parsed;
        my $raw = $json->{profiles} // {};
        for my $name (keys %$raw) {
            $parsed{$name} =
                Temporalio::EnvConfig::ClientConfigProfile->_from_hash(
                    $raw->{$name});
        }
        return $class->new(profiles => \%parsed);
    }

    # load_client_connect_config(%kwargs) — convenience combining a
    # single-profile load (env overrides applied) with to_connect_config (spec
    # section 31.1). Returns a hashref of connect kwargs; the caller deletes
    # 'target' for the positional argument.
    sub load_client_connect_config ($class, %kw) {
        # config_file is an alias for config_source (a file path), ignored when
        # file loading is disabled (mirrors the reference convenience helpers).
        if (defined(my $config_file = delete $kw{config_file})) {
            $kw{config_source} //= $config_file unless $kw{disable_file};
        }
        my $profile =
            Temporalio::EnvConfig::ClientConfigProfile->load(%kw);
        return $profile->to_connect_config;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::EnvConfig::ClientConfig - all parsed env-config profiles

=head1 SYNOPSIS

    my $config = Temporalio::EnvConfig::ClientConfig->load;
    my $prod   = $config->profiles->{prod};

    # Or the one-shot convenience:
    my %connect = %{ Temporalio::EnvConfig::ClientConfig
        ->load_client_connect_config(profile => 'prod') };

=head1 DESCRIPTION

A container value class holding every named profile parsed from the
configuration (spec section 31.1). Use L</load> for the full set of profiles
(no env overrides applied) or L</load_client_connect_config> for the common
single-profile-to-connect-kwargs path.

=head1 METHODS

=head2 profiles

    my $hashref = $config->profiles;

Map of profile name to L<Temporalio::EnvConfig::ClientConfigProfile>.

=head2 load

    my $config = Temporalio::EnvConfig::ClientConfig->load(
        config_source => $path_or_content,
        config_file_strict => $bool,
        override_env_vars => \%env,
    );

Loads all profiles. Applies no environment overrides to the profiles; only
consults the environment for the default config-file path.

=head2 load_client_connect_config

    my $hashref = Temporalio::EnvConfig::ClientConfig->load_client_connect_config(
        profile => $name,
        config_file => $path,
        disable_file => $bool,
        disable_env => $bool,
        config_file_strict => $bool,
        override_env_vars => \%env,
    );

Loads a single profile (env overrides applied) and converts it to
L<Temporalio::Client/connect> kwargs.

=cut
