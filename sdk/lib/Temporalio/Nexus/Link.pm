# ABOUTME: Nexus<->Temporal link conversion (B13 #11, spec section 26.2). The
# ABOUTME: inbound StartOperation request carries caller links as nexus Links
# ABOUTME: (url + type); converting them to temporal.api.common.v1.Link lets a
# ABOUTME: :WorkflowRunOperation attach caller<->backing-workflow correlation to
# ABOUTME: the backing-workflow start. MUST-match sdk-python nexus/_link_conversion.py.
use v5.38;
use warnings;

package Temporalio::Nexus::Link;

use Temporalio::Core::Proto ();

# The two link-type tags the server uses (the proto message full names).
my $TYPE_WORKFLOW        = 'temporal.api.common.v1.Link.WorkflowEvent';
my $TYPE_NEXUS_OPERATION = 'temporal.api.common.v1.Link.NexusOperation';

# nexus_link_to_temporal_link($url, $type) -> a temporal.api.common.v1.Link proto
# or undef. Best-effort: an unknown type or an unparseable URL yields undef (the
# caller drops it), exactly like sdk-python returning None and filtering. A
# decorative link must never break the backing-workflow start.
sub nexus_link_to_temporal_link ($url, $type) {
    return undef unless defined $url && length $url;
    $type //= '';
    my $link = eval {
          $type eq $TYPE_WORKFLOW        ? _workflow_event_link($url)
        : $type eq $TYPE_NEXUS_OPERATION ? _nexus_operation_link($url)
        :                                  undef;
    };
    return $link;   # eval failure -> undef
}

# Percent-decode a URL component (the server percent-encodes path/query parts).
sub _unescape ($s) {
    return '' unless defined $s;
    $s =~ s/\+/ /g;
    $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $s;
}

# Split a "k=v&k2=v2" query string into a { k => v } hashref (last value wins).
sub _parse_query ($query) {
    my %q;
    return \%q unless defined $query && length $query;
    for my $pair (split /&/, $query) {
        my ($k, $v) = split /=/, $pair, 2;
        $q{ _unescape($k) } = _unescape($v // '');
    }
    return \%q;
}

# temporal://.../namespaces/{ns}/workflows/{wfid}/{runid}/history?<query> ->
# common.v1.Link{ workflow_event => WorkflowEvent{...} }.
sub _workflow_event_link ($url) {
    my ($path, $query) = _split_path_query($url);
    return undef unless $path =~
        m{^/namespaces/([^/]+)/workflows/([^/]+)/([^/]+)/history$};
    my ($ns, $wid, $rid) = (_unescape($1), _unescape($2), _unescape($3));
    my $q = _parse_query($query);

    my %we = (namespace => $ns, workflow_id => $wid, run_id => $rid);
    my $ref_type = $q->{referenceType} // '';
    if ($ref_type eq 'RequestIdReference') {
        my $RequestIdRef = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.Link.WorkflowEvent.RequestIdReference');
        $we{request_id_ref} = $RequestIdRef->new({
            request_id => ($q->{requestID} // ''),
            event_type => _event_type_enum($q->{eventType}),
        });
    }
    elsif ($ref_type eq 'EventReference') {
        my $EventRef = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.Link.WorkflowEvent.EventReference');
        $we{event_ref} = $EventRef->new({
            event_id   => int($q->{eventID} // 0),
            event_type => _event_type_enum($q->{eventType}),
        });
    }

    my $WorkflowEvent = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.Link.WorkflowEvent');
    my $Link = Temporalio::Core::Proto::resolve('temporal.api.common.v1.Link');
    return $Link->new({ workflow_event => $WorkflowEvent->new(\%we) });
}

# temporal://.../namespaces/{ns}/nexus-operations/{opid}?runID=... ->
# common.v1.Link{ nexus_operation => NexusOperation{...} }.
sub _nexus_operation_link ($url) {
    my ($path, $query) = _split_path_query($url);
    return undef unless $path =~
        m{^/namespaces/([^/]+)/nexus-operations/([^/]+)$};
    my ($ns, $opid) = (_unescape($1), _unescape($2));
    my $q = _parse_query($query);

    my $NexusOp = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.Link.NexusOperation');
    my $Link = Temporalio::Core::Proto::resolve('temporal.api.common.v1.Link');
    return $Link->new({
        nexus_operation => $NexusOp->new({
            namespace    => $ns,
            operation_id => $opid,
            run_id       => ($q->{runID} // ''),
        }),
    });
}

# Strip the scheme/authority and return ($path, $query). The server emits
# `temporal://` with an empty authority, so the path starts at the first '/'.
sub _split_path_query ($url) {
    my $rest = $url;
    $rest =~ s{^[^:]+://}{};            # drop scheme://
    $rest =~ s{^[^/]*}{};               # drop any authority before the path
    my ($path, $query) = split /\?/, $rest, 2;
    return ($path // '', $query);
}

# Map an eventType query value to the proto EventType enum NUMBER (the generated
# message classes validate enum fields as integers). The server emits PascalCase
# (e.g. "NexusOperationScheduled"); normalize to the EVENT_TYPE_CONSTANT_CASE
# enum name, then resolve its number from the schema. A value already in
# EVENT_TYPE_* form is used directly; an unknown/empty value -> 0 (UNSPECIFIED).
sub _event_type_enum ($raw) {
    return 0 unless defined $raw && length $raw;
    my $name = $raw;
    if ($name !~ /^EVENT_TYPE_/ && $name =~ /^[A-Z][a-z]/) {
        (my $constant = $name) =~ s/([A-Z])/_$1/g;
        $constant =~ s/^_//;
        $name = 'EVENT_TYPE_' . uc($constant);
    }
    return _event_type_number($name) // 0;
}

# EventType enum name -> number via the loaded schema, cached. undef for an
# unknown name (the caller falls back to 0/UNSPECIFIED).
my %EVENT_TYPE_NUMBER;
sub _event_type_number ($name) {
    if (!%EVENT_TYPE_NUMBER) {
        my $enum = Temporalio::Core::Proto::schema()
            ->enum('temporal.api.enums.v1.EventType');
        for my $v (@{ $enum ? $enum->values : [] }) {
            $EVENT_TYPE_NUMBER{ $v->{name} } = $v->{number};
        }
    }
    return $EVENT_TYPE_NUMBER{$name};
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Nexus::Link - Nexus<->Temporal link conversion (B13 #11)

=head1 DESCRIPTION

Converts the inbound Nexus C<StartOperationRequest> links (each a
C<temporal.api.nexus.v1.Link> with a C<url> and a C<type>) into
C<temporal.api.common.v1.Link> messages, so a C<:WorkflowRunOperation> can attach
caller<->backing-workflow correlation links to the backing-workflow start. The
URL grammar and the PascalCase<->CONSTANT_CASE event-type mapping MUST-match
sdk-python C<nexus/_link_conversion.py>.

=head1 FUNCTIONS

=head2 nexus_link_to_temporal_link

C<< nexus_link_to_temporal_link($url, $type) >> returns a
C<temporal.api.common.v1.Link> proto, or C<undef> for an unknown link type or an
unparseable URL (the caller drops it: a decorative link never breaks the start).

=cut
