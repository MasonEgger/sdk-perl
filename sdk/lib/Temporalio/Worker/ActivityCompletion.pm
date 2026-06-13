# ABOUTME: Builds coresdk.ActivityTaskCompletion protos for the three outcomes
# ABOUTME: of an activity task — success, failure, cancellation (spec section 8.4
# ABOUTME: step 7). Shared with the workflow side later; payload/failure inputs
# ABOUTME: are already converted + codec-encoded by the caller.
use v5.38;
use warnings;

package Temporalio::Worker::ActivityCompletion;

use Temporalio::Core::Proto ();

# Resolve the result/completion message classes once at load.
my $Completion = Temporalio::Core::Proto::resolve('coresdk.ActivityTaskCompletion');
my $Result     = Temporalio::Core::Proto::resolve(
    'coresdk.activity_result.ActivityExecutionResult');
my $Success    = Temporalio::Core::Proto::resolve(
    'coresdk.activity_result.Success');
my $Failure    = Temporalio::Core::Proto::resolve(
    'coresdk.activity_result.Failure');
my $Cancellation = Temporalio::Core::Proto::resolve(
    'coresdk.activity_result.Cancellation');

# success($task_token, $result_payload) -> serialized ActivityTaskCompletion.
# $result_payload is a temporal.api.common.v1.Payload (already converted +
# codec-encoded). A void activity passes undef, which the proto encodes as an
# absent result field (mirrors the reference SDKs' Success{result: nil}).
sub success ($task_token, $result_payload) {
    return _completion($task_token,
        $Result->new({ completed => $Success->new({ result => $result_payload }) }));
}

# failure($task_token, $failure_proto) -> serialized ActivityTaskCompletion.
# $failure_proto is a temporal.api.failure.v1.Failure (already converted +
# codec-encoded by the data converter's to_failure).
sub failure ($task_token, $failure_proto) {
    return _completion($task_token,
        $Result->new({ failed => $Failure->new({ failure => $failure_proto }) }));
}

# cancelled($task_token, $failure_proto) -> serialized ActivityTaskCompletion.
# Per activity_result.proto: when lang reports a cancelled activity it must put
# a CanceledFailure in the failure field. $failure_proto is the converted
# CancelledFailure.
sub cancelled ($task_token, $failure_proto) {
    return _completion($task_token,
        $Result->new({ cancelled => $Cancellation->new({ failure => $failure_proto }) }));
}

sub _completion ($task_token, $result) {
    return $Completion->new({ task_token => $task_token, result => $result })->encode;
}

1;

__END__

=head1 NAME

Temporalio::Worker::ActivityCompletion - build ActivityTaskCompletion protos

=head1 SYNOPSIS

    use Temporalio::Worker::ActivityCompletion ();

    my $bytes = Temporalio::Worker::ActivityCompletion::success(
        $task_token, $result_payload);
    my $bytes = Temporalio::Worker::ActivityCompletion::failure(
        $task_token, $failure_proto);
    my $bytes = Temporalio::Worker::ActivityCompletion::cancelled(
        $task_token, $cancelled_failure_proto);

=head1 DESCRIPTION

Builds the serialized C<coresdk.ActivityTaskCompletion> bytes the activity
dispatcher hands to C<worker_complete_activity_task> (spec section 8.4 step
7). One function per terminal outcome: C<success> (a
C<ActivityExecutionResult{completed}>), C<failure>
(C<ActivityExecutionResult{failed}>), and C<cancelled>
(C<ActivityExecutionResult{cancelled}>). Inputs are already-converted protos:
a C<temporal.api.common.v1.Payload> for the success result, a
C<temporal.api.failure.v1.Failure> for failure/cancellation. Payload codec
encoding (the worker boundary) is the caller's responsibility, so this module
stays a pure proto-shaping helper reusable by the workflow side later.

=cut
