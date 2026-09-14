# ABOUTME: Loads the vendored Temporal .proto trees once via Protobuf::Parser and
# ABOUTME: generates Temporalio::Proto::* message classes (spec section 4.6).
package Temporalio::Core::Proto;

use v5.38;
use warnings;

use Cwd ();
use File::Find ();
use File::ShareDir ();
use File::Spec ();
use Protobuf::Parser ();
use Protobuf::Schema ();
use Protobuf::Codec ();
use Protobuf::JSON ();
use Protobuf::Class::Generator ();
use Scalar::Util ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Runtime ();

# One-shot load guard and the full-name -> generated-package registry that
# backs resolve(). Both are process-global: the generated classes land in
# the shared Perl symbol table anyway, so there is exactly one registry.
my $LOADED = 0;
my %CLASS_FOR;    # 'temporal.api.failure.v1.Failure' => 'Temporalio::Proto::...'
my $SCHEMA;       # the resolved Protobuf::Schema behind the generated classes
my $JSON;         # shared Protobuf::JSON over $SCHEMA, built on first use

# load: parse the vendored proto graph and generate every message class.
# Idempotent — subsequent calls no-op. Dies with the offending file path when
# a .proto fails to load (spec section 4.6 failure mode, re-vendor guard).
sub load {
    return 1 if $LOADED;

    my $root   = _proto_root();
    my $parser = Protobuf::Parser->new(include_paths => [$root, _wkt_root()]);

    # Collect the whole reachable graph into ONE schema: a shared parser
    # dedupes diamond imports by absolute path; the file-name grep dedupes
    # across the root files' overlapping subgraphs.
    my $schema = Protobuf::Schema->new;
    for my $rel (_root_files($root)) {
        my $sub = eval { $parser->parse_with_imports($rel) };
        die "Temporalio::Core::Proto: failed to load proto '$rel': $@"
            unless $sub;
        $schema->add_file($_)
            for grep { !$schema->file($_->name) } $sub->files->@*;
    }
    $schema->resolve;

    # Generate a Perl class for every (non-map-entry) message, walking each
    # file's message tree so nested messages land under their parent class.
    for my $file ($schema->files->@*) {
        _build_messages($schema, _perl_package($file->package), $file->messages);
    }

    $SCHEMA = $schema;
    $LOADED = 1;
    return 1;
}

# schema() -> the resolved Protobuf::Schema behind the generated classes.
# Loads on first use.
sub schema {
    load();
    return $SCHEMA;
}

# json() -> a shared Protobuf::JSON codec over the loaded schema, for the
# proto3 canonical JSON form (the json/protobuf payload encoding). Loads on
# first use; one instance per process, like the class registry.
sub json {
    load();
    $JSON //= Protobuf::JSON->new(
        codec  => Protobuf::Codec->new(schema => $SCHEMA),
        schema => $SCHEMA,
    );
    return $JSON;
}

# resolve('temporal.api.failure.v1.Failure')
#   -> 'Temporalio::Proto::Api::Failure::V1::Failure'
# Plain function (spec section 4.6). Loads on first use; throws
# Temporalio::Exception::Runtime for a full name with no generated class.
sub resolve ($full_name) {
    load();
    my $pkg = $CLASS_FOR{$full_name}
        or Temporalio::Exception::Runtime->throw(
            message => "no generated proto class for '$full_name'");
    return $pkg;
}

# The inclusive bound on google.protobuf.Duration.seconds (10000 years either
# way), MUST-matched to _DURATION_SECONDS_MAX in protobuf's
# google/protobuf/internal/well_known_types.py (checked against protobuf
# 6.33.6). Well inside 2**53, so a value that passes this check also survives
# the float-to-int64 encode.
my $DURATION_SECONDS_MAX = 315_576_000_000;

# duration_from_seconds($seconds) -> google.protobuf.Duration instance.
# Perl-side seconds (possibly fractional) split into Duration { seconds,
# nanos }. No undef handling here: every call site already guards for
# definedness before calling (I14; formerly duplicated as
# Converter/Failure.pm's _duration_from_seconds, Common/RetryPolicy.pm's,
# Client.pm's, Workflow/Runner.pm's, and Schedule::{Policy,Interval,Action,
# Spec}'s local _duration).
#
# Rounding follows Duration._NormalizeDuration and _CheckDurationValid in
# protobuf's google/protobuf/internal/well_known_types.py (checked against
# protobuf 6.33.6): seconds and nanos always share a sign, and nanos
# stay within [-999999999, 999999999]. Two consequences (F10):
#   1. The fraction is rounded on its ABSOLUTE value and the sign applied
#      afterwards. The old `int(($seconds - int($seconds)) * 1e9 + 0.5)` split
#      -1.5 into (-1, -499999999), one nanosecond short, because +0.5 rounds a
#      negative fraction toward zero.
#   2. A fraction within half a nanosecond of the next second carries into
#      seconds. The old form left nanos at 1_000_000_000 (0.9999999999 gave
#      (0, 1000000000)), which is outside the proto-legal range.
#
# Non-numeric input, non-finite input (NaN, +/-Inf), and input beyond the
# Duration range throw Temporalio::Exception::Argument rather than encoding a
# mangled int64. The check lives here because this pair is the single choke
# point for every seconds-to-Duration call site. It is the full house guard
# from Common/Priority.pm's ADJUST block (:57-60), both halves:
#   * looks_like_number rejects a string Perl would numify quietly. Without
#     it 'abc' and '' encode as a zero Duration and '3abc' as 3 seconds, with
#     nothing louder than a numeric warning to say so.
#   * `$s - $s != 0` is the finite check: for finite x, x - x is exactly 0,
#     while Inf - Inf and NaN - NaN are both NaN. It is still needed after
#     looks_like_number, which accepts the strings 'Inf' and 'NaN'.
# Numeric strings ('1.5', '1e3', a padded ' 1') pass both halves and convert
# like the numbers they spell.
sub duration_from_seconds ($seconds) {
    Temporalio::Exception::Argument->throw(
        message => "duration seconds must be a finite number, got '$seconds'")
        if !Scalar::Util::looks_like_number($seconds)
        || $seconds - $seconds != 0;
    Temporalio::Exception::Argument->throw(
        message => "duration seconds $seconds is outside the "
            . "google.protobuf.Duration range [-$DURATION_SECONDS_MAX, "
            . "$DURATION_SECONDS_MAX]")
        if abs($seconds) > $DURATION_SECONDS_MAX;

    my $Duration = resolve('google.protobuf.Duration');
    my $sign  = $seconds < 0 ? -1 : 1;
    my $magn  = abs($seconds);
    my $whole = int($magn);
    my $nanos = int(($magn - $whole) * 1_000_000_000 + 0.5);
    if ($nanos >= 1_000_000_000) {
        $whole += 1;
        $nanos -= 1_000_000_000;
    }
    return $Duration->new(
        { seconds => $sign * $whole, nanos => $sign * $nanos });
}

# seconds_from_duration($duration) -> Perl-side seconds (possibly fractional),
# or undef when $duration is unset. The inverse of duration_from_seconds
# (I14; formerly duplicated as Converter/Failure.pm's _seconds_from_duration
# and the local _duration_to_seconds in Common/RetryPolicy.pm and
# Schedule::{Policy,Interval,Action}; Schedule::Spec keeps its own
# unset-Duration-reads-as-undef check at the call site since that behavior
# is not shared by the other copies).
sub seconds_from_duration ($duration) {
    return undef unless defined $duration;
    return ($duration->seconds // 0) + ($duration->nanos // 0) / 1_000_000_000;
}

# The vendored proto root: the checkout's sdk/share/proto when running from
# the source tree (prove -l), else the installed distribution share dir.
sub _proto_root {
    my ($vol, $dir) = File::Spec->splitpath(__FILE__);
    # __FILE__ is .../lib/Temporalio/Core/Proto.pm; share/ sits at the dist
    # root, three directories up from lib/Temporalio/Core/.
    my $dev = File::Spec->catdir($vol . $dir,
        (File::Spec->updir) x 3, 'share', 'proto');
    return Cwd::abs_path($dev) if -d $dev;

    my $installed = eval {
        File::Spec->catdir(File::ShareDir::dist_dir('Temporalio-SDK'), 'proto');
    };
    return $installed if defined $installed && -d $installed;

    die 'Temporalio::Core::Proto: vendored proto root not found '
      . '(checked the checkout share/proto and the Temporalio-SDK dist share); '
      . "re-run xt/author/vendor-protos.pl\n";
}

# The Protobuf distribution's bundled well-known-type root. The parser's own
# WKT auto-include only works from a Protobuf CHECKOUT (it resolves relative
# to Protobuf/Parser.pm); for an installed Protobuf the share lives under
# auto/share/dist, so pass it as an explicit include path. Empty list when it
# cannot be located — the parser's auto-include then covers the checkout case.
sub _wkt_root {
    my $dir = eval {
        File::Spec->catdir(File::ShareDir::dist_dir('Protobuf'), 'proto');
    };
    return (defined $dir && -d $dir) ? ($dir) : ();
}

# The root .proto files to parse (spec section 4.6): every
# temporal/api/workflowservice/v1/*.proto, (spec R91, for the raw
# operator-service client) temporal/api/operatorservice/v1/*.proto, and (I12,
# for the raw cloud/test/health service clients)
# temporal/api/cloud/cloudservice/v1/*.proto and
# temporal/api/testservice/v1/*.proto, plus every coresdk root under
# temporal/sdk/core/. The *_fq.proto variant is EXCLUDED: it redefines the
# coresdk.workflow_activation package with fully-qualified type names (a
# codegen aid sdk-core itself does not compile), so parsing it would collide
# with workflow_activation.proto in the schema index. Paths are relative to
# $root and sorted for determinism.
sub _root_files ($root) {
    my @roots;

    for my $service_dir (
        [qw(workflowservice v1)],
        [qw(operatorservice v1)],
        [qw(cloud cloudservice v1)],
        [qw(testservice v1)],
    ) {
        my $svc = File::Spec->catdir($root, 'temporal', 'api', @$service_dir);
        push @roots, glob File::Spec->catfile($svc, '*.proto');
    }

    File::Find::find({
        no_chdir => 1,
        wanted   => sub {
            return unless -f $File::Find::name
                && $File::Find::name =~ /\.proto\z/
                && $File::Find::name !~ /_fq\.proto\z/;
            push @roots, $File::Find::name;
        },
    }, File::Spec->catdir($root, qw(temporal sdk core)));

    # Messages reachable only through a google.protobuf.Any, never via an
    # import: the gRPC error envelope and the Temporal error-details payloads
    # it carries (spec section 7.5). Parse them as explicit roots; a missing
    # file dies in load() with its path, the same re-vendor guard as any
    # other root.
    push @roots,
        File::Spec->catfile($root, qw(google rpc status.proto)),
        File::Spec->catfile($root, qw(temporal api errordetails v1 message.proto));

    # grpc.health.v1.Health (I12, for the raw health-service client): it
    # lives outside temporal/api/, so add it explicitly the same way as the
    # google/rpc/status.proto root above.
    push @roots, File::Spec->catfile($root, qw(grpc health v1 health.proto));

    return sort map { File::Spec->abs2rel($_, $root) } @roots;
}

# Mechanical proto-package -> Perl-package mapping (spec section 4.6): drop a
# leading 'temporal' component, CamelCase the rest (underscore-separated words
# each ucfirst'd), and prefix Temporalio::Proto::.
#   temporal.api.common.v1       -> Temporalio::Proto::Api::Common::V1
#   coresdk.workflow_activation  -> Temporalio::Proto::Coresdk::WorkflowActivation
#   google.protobuf              -> Temporalio::Proto::Google::Protobuf
sub _perl_package ($proto_package) {
    my @parts = split /\./, ($proto_package // '');
    shift @parts if @parts && $parts[0] eq 'temporal';
    @parts = map { join '', map { ucfirst } split /_/ } @parts;
    return join '::', 'Temporalio::Proto', @parts;
}

# Depth-first class generation over a file's (or message's nested) messages.
# Message names are already CamelCase in the protos and are appended verbatim;
# synthetic map-entry messages get no class (the codec handles maps natively).
sub _build_messages ($schema, $prefix, $messages) {
    for my $message (@$messages) {
        next if $message->is_map_entry;
        my $pkg = "${prefix}::" . $message->name;
        Protobuf::Class::Generator->build(
            schema         => $schema,
            message        => $message,
            target_package => $pkg,
        );
        $CLASS_FOR{ $message->full_name } = $pkg;
        _build_messages($schema, $pkg, $message->nested_messages);
    }
    return;
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Core::Proto - load vendored Temporal protos, generate message classes

=head1 SYNOPSIS

    use Temporalio::Core::Proto;

    Temporalio::Core::Proto->load;    # idempotent

    my $act = Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation
        ->new({ run_id => 'r1' });
    my $bytes = $act->encode;
    my $back  = Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation
        ->decode($bytes);

    my $class = Temporalio::Core::Proto::resolve('temporal.api.failure.v1.Failure');
    # 'Temporalio::Proto::Api::Failure::V1::Failure'

    my $schema = Temporalio::Core::Proto::schema();   # the resolved Protobuf::Schema
    my $json   = Temporalio::Core::Proto::json();     # shared Protobuf::JSON codec

=head1 DESCRIPTION

Parses the complete vendored proto trees under C<share/proto> with the
pure-Perl L<Protobuf::Parser> (no C<protoc>, no C<libprotobuf>) and installs a
Perl class for every message under C<Temporalio::Proto::*> via
L<Protobuf::Class::Generator>.

Every vendored file is byte-identical to the pinned sdk-rust tag, which holds
them under C<crates/common/protos/>: the Temporal C<api_upstream> tree, the
coresdk C<local> tree, C<google/rpc>, and (for the raw cloud, test, and health
service clients) C<api_cloud_upstream>, C<testsrv_upstream>,
C<grpc/health/v1>, and C<protoc-gen-openapiv2/options>. Re-vendor from the tag
path, never from a checkout's current C<HEAD>; a file from a later upstream can
carry a field the pinned c-bridge's own decode drops on the way through.

The package mapping is mechanical: the proto package's leading C<temporal>
component is dropped, the remaining components are CamelCased, and the result
is prefixed with C<Temporalio::Proto::>. The C<google.protobuf> well-known
types are not vendored; they resolve from the L<Protobuf> distribution's own
share directory.

C<load> dies with the offending file path when any C<.proto> fails to parse —
the guard against a bad re-vendor. C<resolve> maps a protobuf full name to its
generated class and throws L<Temporalio::Exception::Runtime> for an unknown
name. C<schema> returns the resolved L<Protobuf::Schema> behind the generated
classes, and C<json> returns a process-shared L<Protobuf::JSON> codec over it
(used for the C<json/protobuf> payload encoding). All entry points load the
protos on first use.

=head1 METHODS

=head2 duration_from_seconds

Converts Perl-side (possibly fractional) seconds to a C<google.protobuf.Duration> instance. The shared home (I14) for the seconds-to-Duration conversion formerly duplicated in C<Converter::Failure>, C<Common::RetryPolicy>, C<Client>, C<Workflow::Runner>, and the C<Schedule::*> modules.

The split matches protobuf's own C<Duration._NormalizeDuration> and C<_CheckDurationValid>, so the resulting message is always proto-legal:

=over 4

=item *

B<Sign-aware rounding.> C<seconds> and C<nanos> carry the same sign, and the fractional part is rounded half-away-from-zero on its absolute value: C<-1.5> gives C<< { seconds => -1, nanos => -500000000 } >>, and C<-0.25> gives C<< { seconds => 0, nanos => -250000000 } >>.

=item *

B<Carry at one billion.> A fraction within half a nanosecond of the next second rounds up into C<seconds> rather than leaving C<nanos> at C<1_000_000_000>, which the proto range forbids: C<0.9999999999> gives C<< { seconds => 1, nanos => 0 } >>. C<nanos> therefore always lands in C<[-999999999, 999999999]>.

=item *

B<Non-numeric, non-finite, and out-of-range input throws.> A value that is not a number at all (C<"abc">, C<"">, C<"3abc">, which Perl would otherwise numify quietly to 0, 0, and 3), C<NaN>, C<+Inf>, C<-Inf>, and any magnitude above C<315_576_000_000> seconds (protobuf's inclusive bound, 10000 years either way) all raise L<Temporalio::Exception::Argument>. Callers do not need their own guard: this is the single choke point for every seconds-to-Duration conversion in the SDK. A string that does spell a number is taken as the number it spells, so C<"1.5"> converts like C<1.5>.

=back

=head2 json

Returns the JSON descriptor / mapping used when resolving messages.

=head2 load

Loads and parses the vendored proto trees, generating the C<Temporalio::Proto::*> message classes. Idempotent.

The load is eager and whole-graph: the first call to C<load>, C<schema>, C<json>, or C<resolve> parses every root, including the cloud and testservice roots that only the raw C<CloudService> and C<TestService> handles use. Measured on the F5 re-vendor, warm cache: 67 files, 1.8s, 40 MB peak RSS without those roots and C<grpc/health>; 87 files, 2.4s, 45 MB with them. So a client that never touches a raw cloud or test handle still pays about 0.6s and 5 MB at startup.

That cost is deliberate, because neither way of avoiding it is currently safe. Deferring the two trees to first use fails because L<Protobuf::Schema>'s C<resolve> latches: it returns early once the schema is resolved, so a file added afterwards is indexed but never type-resolved or feature-resolved, and there is no reset short of patching the L<Protobuf> distribution. Parsing them into a I<second> schema fails because C<temporal/api/cloud/nexus/v1/message.proto>, which C<temporal/api/cloud/cloudservice/v1/request_response.proto> pulls in, imports C<temporal/api/common/v1/message.proto>: the second schema would regenerate the shared C<Temporalio::Proto::Api::Common::V1::*> classes over the ones the main schema already installed, and those classes back every payload on the hot path. Revisit if L<Protobuf::Schema> grows an incremental resolve, or a generator mode that skips already-installed packages.

=head2 resolve

Resolves a fully-qualified proto message name (e.g. C<temporal.api.common.v1.Payload>) to its generated Perl class, triggering the one-time vendored-proto load on first use.

=head2 schema

Returns the parsed proto schema object backing message resolution.

=head2 seconds_from_duration

Converts a C<google.protobuf.Duration> instance back to Perl-side (possibly fractional) seconds, or C<undef> when the Duration is unset. The inverse of C<duration_from_seconds>; the shared home (I14) for the Duration-to-seconds conversion formerly duplicated across the same call sites.

Because C<duration_from_seconds> emits same-sign C<seconds>/C<nanos> pairs, the sum here reproduces the input exactly: C<-1.5> and C<0.9999999999> both survive the round trip (the latter as C<1>, its rounded value). A Duration that reached the SDK with a mismatched sign is summed as given, not normalized.

An all-zero Duration reads back as C<0>, not C<undef>, since the unset-versus-zero distinction is a call-site concern: proto3 cannot tell the two apart on the wire, and only some call sites (C<Schedule::Spec>'s C<jitter>) want zero folded to C<undef>.

=cut
