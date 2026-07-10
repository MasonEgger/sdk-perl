# ABOUTME: Nexus start-operation result wrappers (spec section 26.2):
# ABOUTME: StartOperationResultSync{value} and StartOperationResultAsync{operation_token}.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

# A sync operation result. The dispatcher wraps a plain handler return value in
# one of these (or the handler may return one explicitly); it maps to
# StartOperationResponse.Sync{payload} on the wire (spec section 26.2/26.3).
class Temporalio::Nexus::OperationResult::Sync {
    field $value :param;
    method value { return $value }
}

# An async operation result, carrying the operation token the caller uses to
# reference the started operation. Maps to
# StartOperationResponse.Async{operation_token}. A :WorkflowRunOperation
# handler returns a Temporalio::Nexus::WorkflowHandle, which the dispatcher
# converts into one of these (spec section 26.3).
class Temporalio::Nexus::OperationResult::Async {
    field $operation_token :param;
    method operation_token { return $operation_token }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Nexus::OperationResult - Nexus start-operation result wrappers

=head1 DESCRIPTION

Two result wrappers used by the Nexus dispatcher (spec section 26.2/26.3):

=over 4

=item L<Temporalio::Nexus::OperationResult::Sync>

Carries the operation's C<value>; maps to C<StartOperationResponse.Sync>.

=item L<Temporalio::Nexus::OperationResult::Async>

Carries the C<operation_token>; maps to C<StartOperationResponse.Async>.

=back

=head1 CONSTRUCTOR

=head2 new

C<< Temporalio::Nexus::OperationResult::Sync->new(value => ...) >> or
C<< Temporalio::Nexus::OperationResult::Async->new(operation_token => ...) >>.

=head1 METHODS

=head2 value

(Sync) the operation result value.

=head2 operation_token

(Async) the operation token.

=cut
