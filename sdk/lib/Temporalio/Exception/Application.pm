# ABOUTME: Application-level failure raised by workflow or activity code (spec section 6.2).
# ABOUTME: Carries type/non_retryable/details/category; maps to ApplicationFailureInfo.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Application :isa(Temporalio::Exception) {
    field $type :param = undef;
    field $non_retryable :param = 0;
    field $details :param = undef;
    field $category :param = 'application';

    method type                   { $type }
    method non_retryable          { $non_retryable }
    method details                { $details }
    method category               { $category }
}

1;

__END__

=head1 NAME

Temporalio::Exception::Application - Application-level failure raised by workflow or activity code (spec section 6.2).

=head1 DESCRIPTION

Raised by (or wrapped around) workflow and activity code failures. Maps to the C<application_failure_info> variant of the Temporal Failure proto via L<Temporalio::Converter::Failure>. C<details> is an arrayref of decoded payload values; C<category> is C<application> (default) or C<benign>. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
