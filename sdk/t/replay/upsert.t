# ABOUTME: Replay tests for in-workflow upsert of search attributes & memo (spec
# ABOUTME: section 24): value_set/value_unset emit UpsertWorkflowSearchAttributes
# ABOUTME: (tag 18); upsert_memo set/delete emit ModifyWorkflowProperties (tag
# ABOUTME: 19); info-view updates; empty early-return; conversion-failure before
# ABOUTME: any command; outside a body -> NoRunner (T-upsert-1..9).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Converter::Payload;
use Temporalio::Common::SearchAttributeKey;
use Temporalio::Exception::Workflow::NoRunner;
use Temporalio::Exception::Argument;

no warnings 'experimental::class';

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

sub harness_for ($class) {
    return Temporalio::Test::WorkflowReplay->new(workflow_class => $class);
}

sub init_job (%extra) {
    return { initialize_workflow => { workflow_type => $extra{type}, %{ $extra{fields} // {} } } };
}

# Find the single command of a given variant; fails the subtest if not exactly one.
sub one_of ($cmds, $variant) {
    my @hit = grep { $_->which_variant eq $variant } @$cmds;
    return $hit[0];
}

# ---------------------------------------------------------------------------
# T-upsert-1: value_set emits one UpsertWorkflowSearchAttributes with the
# encoded indexed_fields{key} (tag 18, typed metadata present).
# ---------------------------------------------------------------------------
T2->subtest('value_set emits UpsertWorkflowSearchAttributes (T-upsert-1)' => sub {
    my $h = harness_for('WfDef::SearchAttributeUpserter');
    my @cmds = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ init_job(type => 'SearchAttributeUpserter') ],
    }));

    my $cmd = one_of(\@cmds, 'upsert_workflow_search_attributes');
    T2->ok($cmd, 'an UpsertWorkflowSearchAttributes command was emitted');
    my $sa = $cmd->upsert_workflow_search_attributes->search_attributes;
    my $field = $sa->indexed_fields->{CustomKeywordField};
    T2->ok($field, 'indexed_fields carries the upserted key');
    T2->is($field->metadata->{type}, 'Keyword',
        'value_set payload carries the typed SA metadata');
    T2->is($field->data, '"first"', 'value_set payload encodes the value (json)');
});

# ---------------------------------------------------------------------------
# T-upsert-2: value_unset emits a null Payload (delete) with the command still
# present (key still in indexed_fields).
# ---------------------------------------------------------------------------
T2->subtest('value_unset emits a null Payload, command present (T-upsert-2)' => sub {
    my $h = harness_for('WfDef::SearchAttributeUpserter');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ init_job(type => 'SearchAttributeUpserter') ],
    }));

    my @cmds = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { signal_workflow => { signal_name => 'clear', input => [] } } ],
    }));

    my $cmd = one_of(\@cmds, 'upsert_workflow_search_attributes');
    T2->ok($cmd, 'value_unset still emits an UpsertWorkflowSearchAttributes');
    my $field = $cmd->upsert_workflow_search_attributes->search_attributes
        ->indexed_fields->{CustomKeywordField};
    T2->ok($field, 'the cleared key is still present in indexed_fields');
    T2->is($field->metadata->{encoding}, 'binary/null',
        'value_unset writes a proper null Payload (no type metadata)');
    T2->ok(!exists $field->metadata->{type},
        'null Payload omits the SA type metadata (server-delete convention)');
});

# ---------------------------------------------------------------------------
# T-upsert-3: two sequential upserts; final info->{search_attributes} keeps
# untouched keys, shows cleared/added keys; no BinaryChecksums.
# ---------------------------------------------------------------------------
T2->subtest('sequential upserts update info->{search_attributes} (T-upsert-3)' => sub {
    my $h = harness_for('WfDef::SearchAttributeUpserter');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ init_job(type => 'SearchAttributeUpserter') ],
    }));

    # After init the value_set('first') from :Run is in the info view.
    my $info0 = $h->runner->info;
    T2->is($info0->{search_attributes}{CustomKeywordField}, 'first',
        'value_set from :Run is reflected in info->{search_attributes}');
    T2->ok(!exists $info0->{search_attributes}{BinaryChecksums},
        'info->{search_attributes} is NOT keyed by BinaryChecksums');

    # set -> CustomKeywordField becomes 'second'.
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { signal_workflow =>
            { signal_name => 'set', input => [ payload('second') ] } } ],
    }));
    T2->is($h->runner->info->{search_attributes}{CustomKeywordField}, 'second',
        'a second upsert overwrites the value in info');

    # clear -> the key is removed from the info view.
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 102 },
        jobs      => [ { signal_workflow => { signal_name => 'clear', input => [] } } ],
    }));
    T2->ok(!exists $h->runner->info->{search_attributes}{CustomKeywordField},
        'value_unset removes the key from info->{search_attributes}');
});

# ---------------------------------------------------------------------------
# T-upsert-4: start-time SAs (from InitializeWorkflow) reflected in
# info->{search_attributes}.
# ---------------------------------------------------------------------------
T2->subtest('start-time SAs reflected in info (T-upsert-4)' => sub {
    my $key = Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField');
    my $h = harness_for('WfDef::InfoWaiter');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ init_job(type => 'InfoWaiter', fields => {
            search_attributes => {
                indexed_fields => { CustomKeywordField => $key->encode_value('start') },
            },
        }) ],
    }));

    T2->is($h->runner->info->{search_attributes}{CustomKeywordField}, 'start',
        'a start-time search attribute lands in info->{search_attributes}');
});

# ---------------------------------------------------------------------------
# T-upsert-5: upsert_memo({reason=>'x'}) -> ModifyWorkflowProperties with
# upserted_memo.fields{reason}.
# ---------------------------------------------------------------------------
T2->subtest('upsert_memo set emits ModifyWorkflowProperties (T-upsert-5)' => sub {
    my $h = harness_for('WfDef::MemoUpserter');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ init_job(type => 'MemoUpserter') ],
    }));

    my @cmds = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { signal_workflow =>
            { signal_name => 'set', input => [ payload('x') ] } } ],
    }));

    my $cmd = one_of(\@cmds, 'modify_workflow_properties');
    T2->ok($cmd, 'a ModifyWorkflowProperties command was emitted');
    my $field = $cmd->modify_workflow_properties->upserted_memo->fields->{reason};
    T2->ok($field, 'upserted_memo.fields carries the memo key');
    T2->is($field->data, 'x', 'the memo value is encoded onto the field');
    T2->is($h->runner->info->{memo}{reason}, 'x',
        'the in-workflow memo view is kept in sync');
});

# ---------------------------------------------------------------------------
# T-upsert-6: upsert_memo({stale=>undef}) -> empty Payload (delete), command
# present even if the key is absent.
# ---------------------------------------------------------------------------
T2->subtest('upsert_memo delete emits empty Payload, command present (T-upsert-6)' => sub {
    my $h = harness_for('WfDef::MemoUpserter');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ init_job(type => 'MemoUpserter') ],
    }));

    my @cmds = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { signal_workflow => { signal_name => 'remove', input => [] } } ],
    }));

    my $cmd = one_of(\@cmds, 'modify_workflow_properties');
    T2->ok($cmd, 'removal still emits a ModifyWorkflowProperties command');
    my $field = $cmd->modify_workflow_properties->upserted_memo->fields->{stale};
    T2->ok($field, 'the removed key is present in upserted_memo.fields');
    T2->is($field->metadata->{encoding}, 'binary/null',
        'a removal writes a null/empty Payload (deletion convention)');
});

# ---------------------------------------------------------------------------
# T-upsert-7: empty updates -> no command.
# ---------------------------------------------------------------------------
T2->subtest('empty updates emit no upsert command (T-upsert-7)' => sub {
    my $h = harness_for('WfDef::EmptyUpserter');
    my @cmds = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ init_job(type => 'EmptyUpserter') ],
    }));

    T2->ok(!one_of(\@cmds, 'upsert_workflow_search_attributes'),
        'empty SA updates buffer no command');
    T2->ok(!one_of(\@cmds, 'modify_workflow_properties'),
        'an empty memo hashref buffers no command');
    T2->ok(one_of(\@cmds, 'complete_workflow_execution'),
        'the workflow still completes');
});

# ---------------------------------------------------------------------------
# T-upsert-8: conversion failure -> raises before any command (the activation
# fails with no partial ModifyWorkflowProperties command).
# ---------------------------------------------------------------------------
T2->subtest('conversion failure raises before any command (T-upsert-8)' => sub {
    my $h = harness_for('WfDef::BadMemoUpserter');
    my $completion = $h->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ init_job(type => 'BadMemoUpserter') ],
    }));

    my @cmds = $h->commands_of($completion);
    T2->ok(!one_of(\@cmds, 'modify_workflow_properties'),
        'no partial ModifyWorkflowProperties command on conversion failure');
    T2->ok(!one_of(\@cmds, 'complete_workflow_execution'),
        'the workflow does not complete after a conversion failure');
});

# ---------------------------------------------------------------------------
# T-upsert-9: either verb outside a workflow body -> NoRunner.
# ---------------------------------------------------------------------------
T2->subtest('either verb outside a body raises NoRunner (T-upsert-9)' => sub {
    my $key = Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField');

    my $e1 = T2->dies(sub {
        Temporalio::Workflow::upsert_search_attributes($key->value_set('x'));
    });
    T2->ok(Scalar::Util::blessed($e1)
        && $e1->isa('Temporalio::Exception::Workflow::NoRunner'),
        'upsert_search_attributes outside a body raises NoRunner');

    my $e2 = T2->dies(sub {
        Temporalio::Workflow::upsert_memo({ reason => 'x' });
    });
    T2->ok(Scalar::Util::blessed($e2)
        && $e2->isa('Temporalio::Exception::Workflow::NoRunner'),
        'upsert_memo outside a body raises NoRunner');
});

# ---------------------------------------------------------------------------
# Resolved decision (spec section 24.3): an untyped SA mapping passed to
# upsert_search_attributes -> Argument (reject the Python-deprecated overload).
# ---------------------------------------------------------------------------
T2->subtest('untyped SA mapping is rejected with Argument' => sub {
    my $h = harness_for('WfDef::InfoWaiter');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ init_job(type => 'InfoWaiter') ],
    }));

    my $err = T2->dies(sub {
        $h->runner->upsert_search_attributes({ CustomKeywordField => 'x' });
    });
    T2->ok(Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Argument'),
        'an untyped hashref update raises Argument (typed-only surface)');
});

T2->done_testing;
