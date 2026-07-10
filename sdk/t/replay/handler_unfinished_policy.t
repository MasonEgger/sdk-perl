# ABOUTME: Replay tests for the per-handler unfinished policy (spec R87; parity
# ABOUTME: audit, in-workflow finding 5): a handler declared with
# ABOUTME: unfinished_policy=ABANDON completes the workflow with NO
# ABOUTME: unfinished-handler warning, the default (WARN_AND_ABANDON) still
# ABOUTME: warns, and :Signal honors the same option as :Update.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Workflow::Attributes;
use Temporalio::Converter::Payload;

no warnings 'experimental::class';

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# ---------------------------------------------------------------------------
# R87 update/ABANDON: :Run returns while an in-flight :Update handler declared
# with unfinished_policy=ABANDON is still pending. The workflow completes and
# NO unfinished-handler warning is emitted (Python _handlers.py:36 ABANDON).
# ---------------------------------------------------------------------------
T2->subtest('ABANDON update handler completes with no warning (R87)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::AbandonHandlers',
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'AbandonHandlers',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-r87-u',
                name                 => 'slowUpdate',
                input                => [ payload('Alice') ],
                run_validator        => 1,
            } },
        ],
    }));

    T2->ok((grep { $_->which_variant eq 'complete_workflow_execution' } @cmds),
        'the workflow completes despite the in-flight ABANDON handler');
    T2->is([ grep { /unfinished/i } @warnings ], [],
        'no unfinished-handler warning for an ABANDON update handler');
});

# ---------------------------------------------------------------------------
# R87 update/default: the same shape with NO declared policy (the
# WfDef::ReturningUpdater fixture) still warns — the default is
# WARN_AND_ABANDON (Python _handlers.py:36).
# ---------------------------------------------------------------------------
T2->subtest('default-policy update handler still warns (R87)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ReturningUpdater',
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ReturningUpdater',
                arguments     => [],
            } },
            { do_update => {
                id                   => 'u-1',
                protocol_instance_id => 'pi-r87-d',
                name                 => 'slowUpdate',
                input                => [ payload('Alice') ],
                run_validator        => 1,
            } },
        ],
    }));

    T2->ok((grep { $_->which_variant eq 'complete_workflow_execution' } @cmds),
        'the workflow still completes (warn-and-complete)');
    T2->ok((grep { /unfinished/i } @warnings),
        'the default WARN_AND_ABANDON policy warns at completion');
    T2->ok((grep { /update 'slowUpdate'/ } @warnings),
        'the warning names the unfinished update handler');
});

# ---------------------------------------------------------------------------
# R87 signal/ABANDON: a :Signal handler honors the same option — an in-flight
# ABANDON signal handler completes the workflow with no warning.
# ---------------------------------------------------------------------------
T2->subtest('ABANDON signal handler completes with no warning (R87)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::AbandonHandlers',
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'AbandonHandlers',
                arguments     => [],
            } },
            { signal_workflow => {
                signal_name => 'slowSignal',
                input       => [ payload('Bob') ],
            } },
        ],
    }));

    T2->ok((grep { $_->which_variant eq 'complete_workflow_execution' } @cmds),
        'the workflow completes despite the in-flight ABANDON signal handler');
    T2->is([ grep { /unfinished/i } @warnings ], [],
        'no unfinished-handler warning for an ABANDON signal handler');
});

# ---------------------------------------------------------------------------
# R87 signal/default: a default-policy :Signal handler still warns.
# ---------------------------------------------------------------------------
T2->subtest('default-policy signal handler still warns (R87)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ReturningSignaler',
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my @cmds = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ReturningSignaler',
                arguments     => [],
            } },
            { signal_workflow => {
                signal_name => 'slowSignal',
                input       => [ payload('Bob') ],
            } },
        ],
    }));

    T2->ok((grep { $_->which_variant eq 'complete_workflow_execution' } @cmds),
        'the workflow still completes (warn-and-complete)');
    T2->ok((grep { /unfinished/i } @warnings),
        'the default WARN_AND_ABANDON policy warns for signals too');
    T2->ok((grep { /signal 'slowSignal'/ } @warnings),
        'the warning names the unfinished signal handler');
});

# ---------------------------------------------------------------------------
# R87 option validation at the attribute-parse level: an unknown policy value
# is rejected with the valid choices, and :Query (a synchronous handler that
# can never be left unfinished — Python's query() takes no unfinished_policy)
# rejects the option outright.
# ---------------------------------------------------------------------------
T2->subtest('unfinished_policy value and kind validation (R87)' => sub {
    my $err = T2->dies(sub {
        Temporalio::Workflow::Attributes::parse_handler(
            ['unfinished_policy=BOGUS'], 'm', 'Signal');
    });
    T2->like($err->message, qr/unfinished_policy/,
        'an unknown policy value is rejected');
    T2->like($err->message, qr/WARN_AND_ABANDON.*ABANDON|ABANDON.*WARN_AND_ABANDON/s,
        'the rejection lists the valid policies');

    my $qerr = T2->dies(sub {
        Temporalio::Workflow::Attributes::parse_handler(
            ['unfinished_policy=ABANDON'], 'm', 'Query');
    });
    T2->like($qerr->message, qr/Unknown :Query option 'unfinished_policy'/,
        ':Query rejects unfinished_policy (queries are synchronous)');

    # The accepted spellings parse and land in the options.
    my ($name, %opts) = Temporalio::Workflow::Attributes::parse_handler(
        ['slowUpdate', 'unfinished_policy=ABANDON'], 'slow_update', 'Update');
    T2->is($name, 'slowUpdate', 'positional name still parses alongside the option');
    T2->is($opts{unfinished_policy}, 'ABANDON', 'the ABANDON policy is returned');

    my (undef, %defaults) = Temporalio::Workflow::Attributes::parse_handler(
        ['unfinished_policy=WARN_AND_ABANDON'], 'h', 'Signal');
    T2->is($defaults{unfinished_policy}, 'WARN_AND_ABANDON',
        'the explicit WARN_AND_ABANDON spelling parses');
});

T2->done_testing;
