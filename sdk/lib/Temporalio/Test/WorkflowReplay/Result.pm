# ABOUTME: Per-history replay outcome wrappers for the from-history replayer
# ABOUTME: (spec R95): Result{history, replay_failure} and the batch aggregate
# ABOUTME: Results{results, replay_failures}, sdk-python worker/_replayer.py
# ABOUTME: WorkflowReplayResult/WorkflowReplayResults parity.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

# A single workflow replay outcome (sdk-python WorkflowReplayResult): the
# history that was replayed and the failure core surfaced for it (undef on a
# clean replay). A replay_failure does not mean the workflow exited by
# raising; it means the replay itself broke, e.g.
# Temporalio::Exception::Nondeterminism.
#
# These wrappers live in their own file rather than inside WorkflowReplay.pm:
# with Future::AsyncAwait loaded anywhere in the process, perl 5.38.2
# mis-parses a `field ... :param;` in any class that FOLLOWS a method
# containing a `my sub name ()` ("Subroutine attributes must come before the
# signature"), and _replay_session's teardown is exactly that shape.
class Temporalio::Test::WorkflowReplay::Result {
    field $history :param;
    field $replay_failure :param = undef;
    method history        { return $history }
    method replay_failure { return $replay_failure }
}

# Aggregated batch replay results (sdk-python WorkflowReplayResults):
# replay_failures keyed by run id, plus the per-history Result list in push
# order (the synchronous stand-in for Python's workflow_replay_iterator).
class Temporalio::Test::WorkflowReplay::Results {
    field $results :param = [];
    field $replay_failures :param = {};
    method results         { return $results }
    method replay_failures { return $replay_failures }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Test::WorkflowReplay::Result - per-history replay outcomes

=head1 DESCRIPTION

Result wrappers returned by L<Temporalio::Test::WorkflowReplay>'s
C<replay_workflow> and C<replay_workflows> (spec R95; sdk-python
C<worker/_replayer.py> C<WorkflowReplayResult> / C<WorkflowReplayResults>
parity).

C<Temporalio::Test::WorkflowReplay::Result> is one history's outcome.

=head1 METHODS

=head2 history

The L<Temporalio::Client::WorkflowHistory> originally passed for this
replay.

=head2 replay_failure

The failure encountered replaying the history, or C<undef> on a clean
replay. This does not mean the workflow exited by raising an error;
it means the replay itself broke, most notably
L<Temporalio::Exception::Nondeterminism> when the workflow's commands
diverged from the recorded events.

=head1 RESULTS AGGREGATE

C<Temporalio::Test::WorkflowReplay::Results> aggregates a batch:

=over 4

=item C<results>

The per-history C<Result> list, in push order (the synchronous stand-in
for sdk-python's C<workflow_replay_iterator>).

=item C<replay_failures>

A hashref mapping each failing history's run id to its failure, matching
sdk-python's C<WorkflowReplayResults.replay_failures>.

=back

=cut
