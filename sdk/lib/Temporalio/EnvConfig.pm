# ABOUTME: Client environment configuration (spec section 31): loads a TOML
# ABOUTME: profile + TEMPORAL_* env vars by calling the core env-config FFI.
use v5.38;
use warnings;

package Temporalio::EnvConfig;

our $VERSION = '0.2.0';

use JSON::PP ();
use FFI::Platypus::Buffer ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();

# Spec section 31 (CORRECTED): the canonical TOML/env/precedence engine lives
# in Rust core; the C bridge exposes it through
# temporal_core_client_env_config_load (all profiles, no env overrides) and
# temporal_core_client_env_config_profile_load (one profile, env overrides
# applied). This module builds the option structs, invokes those two symbols,
# and parses the returned JSON into the value classes under
# Temporalio::EnvConfig::*. No TOML parser dependency and no per-OS default-path
# helper: core owns all of it. Earlier drafts specced a pure-Perl port; that
# was wrong (would drift from the oracle) and has been removed.

# Verify the two FFI symbols are present (spec section 31.5 pin check). Cheap,
# memoized in Core::FFI, called from every load path so a version skew surfaces
# as a clear error rather than an attach-time failure far from this code.
Temporalio::Core::FFI::assert_env_config_symbols();

# _build_load_options(\@keep, %kwargs) — fills a ClientEnvConfigLoadOptions
# record from the all-profiles loader kwargs (path | data, config_file_strict,
# env_vars). Backing buffers live on @$keep, which the caller holds until the
# FFI call returns.
sub _build_load_options ($keep, %kw) {
    my %rec;
    @rec{qw(path_data path_size)} =
        Temporalio::Core::FFI::keep_buffer($keep, $kw{path});
    @rec{qw(data_data data_size)} =
        Temporalio::Core::FFI::keep_buffer($keep, $kw{data});
    $rec{config_file_strict} = $kw{config_file_strict} ? 1 : 0;
    @rec{qw(env_vars_data env_vars_size)} =
        Temporalio::Core::FFI::keep_buffer($keep, _encode_env_vars($kw{env_vars}));
    return Temporalio::Core::FFI::ClientEnvConfigLoadOptions->new(%rec);
}

# _build_profile_options(\@keep, %kwargs) — fills a
# ClientEnvConfigProfileLoadOptions record from the single-profile loader
# kwargs (profile, path | data, disable_file, disable_env, config_file_strict,
# env_vars).
sub _build_profile_options ($keep, %kw) {
    my %rec;
    @rec{qw(profile_data profile_size)} =
        Temporalio::Core::FFI::keep_buffer($keep, $kw{profile});
    @rec{qw(path_data path_size)} =
        Temporalio::Core::FFI::keep_buffer($keep, $kw{path});
    @rec{qw(data_data data_size)} =
        Temporalio::Core::FFI::keep_buffer($keep, $kw{data});
    $rec{disable_file}       = $kw{disable_file}       ? 1 : 0;
    $rec{disable_env}        = $kw{disable_env}        ? 1 : 0;
    $rec{config_file_strict} = $kw{config_file_strict} ? 1 : 0;
    @rec{qw(env_vars_data env_vars_size)} =
        Temporalio::Core::FFI::keep_buffer($keep, _encode_env_vars($kw{env_vars}));
    return Temporalio::Core::FFI::ClientEnvConfigProfileLoadOptions->new(%rec);
}

# The env_vars option is a JSON object the bridge deserializes back into a map.
# undef means "no override map given" (a NULL ref -> core uses the process
# environment); an empty hashref encodes "{}" (an explicit empty environment).
sub _encode_env_vars ($env_vars) {
    return undef unless defined $env_vars;
    return JSON::PP->new->canonical->utf8->encode($env_vars);
}

# Run a synchronous OrFail-returning env-config FFI call. $invoke->($options_ptr)
# returns the OrFail record. On a non-null fail byte array, raise Argument
# carrying the verbatim core message (profile-not-found, malformed TOML,
# strict-mode unknown key, path+data conflict, both-disabled — all decided by
# core). On success, return the decoded JSON scalar. Both byte arrays are
# bridge-allocated and freed here with a NULL runtime (these buffers are not
# pooled per-runtime, and byte_array_free accepts a NULL runtime).
sub _call_or_fail ($options, $invoke) {
    my $result  = $invoke->($options);
    my $success = $result->success;
    my $fail    = $result->fail;

    if (defined $fail) {
        my $message = _read_and_free_byte_array($fail);
        Temporalio::Exception::Argument->throw(
            message => "environment config load failed: $message");
    }

    # A success pointer is expected; an absent one would be a bridge contract
    # violation, but guard so we never deref NULL.
    Temporalio::Exception::Argument->throw(
        message => 'environment config load returned neither success nor fail')
        unless defined $success;

    return _read_and_free_byte_array($success);
}

# Copy a *const TemporalCoreByteArray's contents into a Perl scalar, then free
# the bridge allocation (NULL runtime: these buffers are not runtime-pooled).
sub _read_and_free_byte_array ($ba_ptr) {
    my $ffi  = Temporalio::Core::FFI::ffi();
    my $view = $ffi->cast(
        'opaque' => 'record(Temporalio::Core::FFI::ByteArray)*', $ba_ptr);
    my $bytes =
        FFI::Platypus::Buffer::buffer_to_scalar($view->data, $view->size);
    Temporalio::Core::FFI::byte_array_free(undef, $ba_ptr);
    return $bytes;
}

# load_client_config(%kwargs) — all-profiles loader (no env overrides applied;
# env is consulted only for the default-config-file path). Returns the decoded
# top-level JSON hashref { profiles => { name => {profile}, ... } }.
sub load_client_config (%kw) {
    my @keep;
    my $options = _build_load_options(\@keep, %kw);
    my $json = _call_or_fail($options,
        \&Temporalio::Core::FFI::client_env_config_load);
    return _decode_json($json);
}

# load_client_config_profile(%kwargs) — single-profile loader with env
# overrides. Returns the decoded profile JSON hashref.
sub load_client_config_profile (%kw) {
    my @keep;
    my $options = _build_profile_options(\@keep, %kw);
    my $json = _call_or_fail($options,
        \&Temporalio::Core::FFI::client_env_config_profile_load);
    return _decode_json($json);
}

sub _decode_json ($json) {
    my $decoded = eval { JSON::PP->new->utf8->decode($json) };
    Temporalio::Exception::Argument->throw(
        message => "environment config JSON parse failed: $@")
        if $@;
    return $decoded;
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::EnvConfig - client environment configuration via the core FFI

=head1 SYNOPSIS

    use Temporalio::EnvConfig::ClientConfig;

    my %connect = %{ Temporalio::EnvConfig::ClientConfig
        ->load_client_connect_config(profile => 'prod') };
    my $target = delete $connect{target};
    my $client = await Temporalio::Client->connect($target, %connect,
        runtime => $runtime);

=head1 DESCRIPTION

Loads Temporal client connection settings from a TOML profile file and
C<TEMPORAL_*> environment variables (spec section 31). The TOML/env/precedence
engine lives in Rust core; this module calls the two env-config FFI symbols
(C<temporal_core_client_env_config_load> and
C<temporal_core_client_env_config_profile_load>) and parses the returned JSON
into the value classes L<Temporalio::EnvConfig::ClientConfig>,
L<Temporalio::EnvConfig::ClientConfigProfile>, and
L<Temporalio::EnvConfig::ClientConfigTLS>.

A load failure (profile not found, malformed TOML, strict-mode unknown key,
path/data conflict, both file+env disabled) raises
L<Temporalio::Exception::Argument> carrying the verbatim core message, before
any RPC.

=head1 FUNCTIONS

=head2 load_client_config

    my $hashref = Temporalio::EnvConfig::load_client_config(%kwargs);

Low-level all-profiles loader. Most callers use
L<Temporalio::EnvConfig::ClientConfig/load> instead.

=head2 load_client_config_profile

    my $hashref = Temporalio::EnvConfig::load_client_config_profile(%kwargs);

Low-level single-profile loader. Most callers use
L<Temporalio::EnvConfig::ClientConfigProfile/load> instead.

=head1 SEE ALSO

L<Temporalio::EnvConfig::ClientConfig>,
L<Temporalio::EnvConfig::ClientConfigProfile>,
L<Temporalio::EnvConfig::ClientConfigTLS>, L<Temporalio::Client>.

=cut
