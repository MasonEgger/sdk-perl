# ABOUTME: Replay tests for spec R25 (finding R11): the continue-as-new command
# ABOUTME: builder carries search_attributes and versioning_intent when the
# ABOUTME: caller sets them, and keeps proto defaults when they are omitted.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;

# Build a WorkflowActivation proto. The job list is the oneof-tagged hashref
# form the generated classes accept.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;
sub payload ($value) { return $PC->to_payload($value) }

# Dispatch one init activation to $class (with optional args) and return the
# ContinueAsNewWorkflowExecution command message.
sub can_command_for ($class, @args) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => $class,
    );
    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'run',
                (@args ? (arguments => [ map { payload($_) } @args ]) : ()),
            } },
        ],
    }));
    my ($cmd) = grep {
        $_->which_variant eq 'continue_as_new_workflow_execution'
    } @commands;
    T2->ok($cmd, 'a ContinueAsNewWorkflowExecution command was emitted');
    return $cmd ? $cmd->continue_as_new_workflow_execution : undef;
}

# ---------------------------------------------------------------------------
# R25 arm 1: both options set -> both proto fields carry the caller's values.
# search_attributes is field 8 (temporal.api.common.v1.SearchAttributes) and
# versioning_intent is field 10 (coresdk.common.VersioningIntent, COMPATIBLE=1)
# of ContinueAsNewWorkflowExecution (sdk/share/proto/temporal/sdk/core/
# workflow_commands/workflow_commands.proto:212,217).
# ---------------------------------------------------------------------------
T2->subtest('set options are carried into the command (R25)' => sub {
    my $can = can_command_for('WfDef::CanWithOptions', 'compatible');
    return unless $can;

    my $sa = $can->search_attributes;
    T2->ok($sa, 'the command carries a SearchAttributes message');
    return unless $sa;
    my $field = $sa->indexed_fields->{CustomKeywordField};
    T2->ok($field, 'indexed_fields carries the caller search-attribute key');
    T2->is($field->metadata->{type}, 'Keyword',
        'the SA payload carries the typed metadata (shared encoder)');
    T2->is($field->data, '"can-sa"',
        'the SA payload encodes the caller value (json)');

    T2->is($can->versioning_intent, 1,
        'versioning_intent "compatible" maps to COMPATIBLE (1)');
});

# ---------------------------------------------------------------------------
# R25 arm 1b: the other named intent value maps to DEFAULT (2);
# coresdk.common.VersioningIntent, common.proto:31.
# ---------------------------------------------------------------------------
T2->subtest('versioning_intent "default" maps to DEFAULT (R25)' => sub {
    my $can = can_command_for('WfDef::CanWithOptions', 'default');
    return unless $can;
    T2->is($can->versioning_intent, 2,
        'versioning_intent "default" maps to DEFAULT (2)');
});

# ---------------------------------------------------------------------------
# R25 arm 2: both options omitted -> proto defaults (search_attributes unset /
# empty, versioning_intent UNSPECIFIED = 0). WfDef::ContinueAsNewer sets
# neither option.
# ---------------------------------------------------------------------------
T2->subtest('omitted options keep proto defaults (R25)' => sub {
    my $can = can_command_for('WfDef::ContinueAsNewer', 1);
    return unless $can;

    my $sa = $can->search_attributes;
    T2->ok(!defined $sa || !%{ $sa->indexed_fields // {} },
        'search_attributes stays unset/empty when the caller omits it');
    T2->is(($can->versioning_intent // 0), 0,
        'versioning_intent stays UNSPECIFIED (0) when the caller omits it');
});

T2->done_testing;
