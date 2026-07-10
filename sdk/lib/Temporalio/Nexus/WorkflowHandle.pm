# ABOUTME: Handle to the workflow backing a Nexus operation (spec section 26.2).
# ABOUTME: Encodes/decodes the base64url operation token (MUST-match sdk-python nexus/_token.py).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use JSON::PP ();
use MIME::Base64 ();

use Temporalio::Exception::Argument ();

# Token type for a workflow-backed Nexus operation. MUST-match sdk-python
# nexus/_token.py OPERATION_TOKEN_TYPE_WORKFLOW = 1.
my $OPERATION_TOKEN_TYPE_WORKFLOW = 1;

# A handle to the workflow that backs a :WorkflowRunOperation. Returned from
# $ctx->start_workflow inside a workflow-run operation handler; the dispatcher
# reads ->to_token to build StartOperationResponse.Async{operation_token}.
# Constructed only by the SDK (WorkflowRunOperationContext::start_workflow) and
# WorkflowHandle::from_token; not by author code directly.
class Temporalio::Nexus::WorkflowHandle {
    field $namespace   :param;
    field $workflow_id :param;

    method namespace   { return $namespace }
    method workflow_id { return $workflow_id }

    # to_token -> base64url-encoded JSON token string. MUST-match sdk-python
    # nexus/_token.py to_token: a base64url-no-padding-encoded compact JSON
    # object {"t":1,"ns":<namespace>,"wid":<workflow_id>}. JSON::PP canonical
    # makes the field order deterministic; the Go server decodes by key.
    method to_token {
        my $json = JSON::PP->new->canonical(1)->utf8;
        my $bytes = $json->encode({
            t   => $OPERATION_TOKEN_TYPE_WORKFLOW,
            ns  => $namespace,
            wid => $workflow_id,
        });
        # base64url, no padding (sdk-python rstrip("=")).
        my $b64 = MIME::Base64::encode_base64url($bytes, '');
        $b64 =~ s/=+\z//;
        return $b64;
    }

    # from_token($token) -> a WorkflowHandle. MUST-match sdk-python
    # nexus/_token.py from_token: decode base64url, parse JSON, validate the
    # 't' type (== 1), reject a present non-zero 'v', require a non-empty string
    # 'wid', require a string 'ns'. A malformed token raises
    # Temporalio::Exception::Argument (analogous to python's TypeError).
    sub from_token ($class, $token) {
        if (!defined $token || !length $token) {
            Temporalio::Exception::Argument->throw(
                message => "invalid workflow token: token is empty");
        }

        my $bytes = eval { MIME::Base64::decode_base64url($token) };
        if (!defined $bytes) {
            Temporalio::Exception::Argument->throw(
                message => "failed to decode token as base64url");
        }

        my $obj = eval { JSON::PP->new->utf8->decode($bytes) };
        if (!defined $obj) {
            Temporalio::Exception::Argument->throw(
                message => "failed to unmarshal workflow operation token");
        }
        if (ref($obj) ne 'HASH') {
            Temporalio::Exception::Argument->throw(
                message => "invalid workflow token: expected object");
        }

        my $type = $obj->{t};
        if (!defined $type || $type != $OPERATION_TOKEN_TYPE_WORKFLOW) {
            Temporalio::Exception::Argument->throw(
                message => "invalid workflow token type: "
                    . (defined $type ? $type : 'undef')
                    . ", expected: $OPERATION_TOKEN_TYPE_WORKFLOW");
        }

        my $version = $obj->{v};
        if (defined $version && $version != 0) {
            Temporalio::Exception::Argument->throw(
                message => "invalid workflow token: 'v' field, if present, "
                    . "must be 0 or null/absent");
        }

        my $workflow_id = $obj->{wid};
        if (!defined $workflow_id || ref($workflow_id) || !length $workflow_id) {
            Temporalio::Exception::Argument->throw(
                message => "invalid workflow token: missing, empty, or "
                    . "non-string workflow ID (wid)");
        }

        my $namespace = $obj->{ns};
        if (!defined $namespace || ref($namespace)) {
            Temporalio::Exception::Argument->throw(
                message => "invalid workflow token: missing or non-string "
                    . "namespace (ns)");
        }

        return $class->new(namespace => $namespace, workflow_id => $workflow_id);
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Nexus::WorkflowHandle - handle to the workflow backing a Nexus operation

=head1 SYNOPSIS

    my $handle = Temporalio::Nexus::WorkflowHandle->new(
        namespace => 'default', workflow_id => 'op-wf-1');
    my $token  = $handle->to_token;
    my $back   = Temporalio::Nexus::WorkflowHandle->from_token($token);

=head1 DESCRIPTION

Returned from C<< $ctx->start_workflow >> inside a C<:WorkflowRunOperation>
handler (spec section 26.2). The Nexus dispatcher reads C<to_token> to build the
C<StartOperationResponse.Async{operation_token}> response.

The token format MUST-match sdk-python C<nexus/_token.py>: a base64url
(no-padding) encoding of the compact JSON object
C<< {"t":1,"ns":<namespace>,"wid":<workflow_id>} >>. C<from_token> validates the
type, version, workflow id, and namespace, raising
L<Temporalio::Exception::Argument> on a malformed token.

=head1 CONSTRUCTOR

=head2 new

    Temporalio::Nexus::WorkflowHandle->new(namespace => ..., workflow_id => ...);

=head1 METHODS

=head2 namespace

The backing workflow's namespace.

=head2 workflow_id

The backing workflow's id.

=head2 to_token

The base64url-encoded operation token string.

=head2 from_token

C<< Temporalio::Nexus::WorkflowHandle->from_token($token) >> decodes and
validates a token into a WorkflowHandle.

=cut
