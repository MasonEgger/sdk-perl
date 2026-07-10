# ABOUTME: Unit tests for spec section 25 schedule data classes (T-sched-unit):
# ABOUTME: proto field remaps, injected default calendar ranges, Range
# ABOUTME: inclusive/inclusive with no +1, the three coexisting inclusivity
# ABOUTME: rules (Range, ScheduleSpec.start_time, Backfill.start_time), and the
# ABOUTME: OverlapPolicy string->enum coercion.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future::AsyncAwait;

use Temporalio::Client ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Schedule ();

Temporalio::Core::Proto->load;

# A converter-only client: the action's _to_proto reads data_converter,
# namespace, identity, and _encode_string_payload_map — never the connection.
sub make_client (%override) {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => $override{namespace} // 'ns-sched',
        identity       => $override{identity}  // 'id-sched@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# ---------------------------------------------------------------------------
# Range: inclusive/inclusive, step 1, no +1.
# ---------------------------------------------------------------------------
T2->subtest('Range inclusive/inclusive, no +1' => sub {
    my $r = Temporalio::Schedule::Range->new(start => 0, end => 30, step => 5);
    my $p = $r->_to_proto;
    T2->is($p->start, 0,  'start verbatim');
    T2->is($p->end,   30, 'end verbatim (no +1)');
    T2->is($p->step,  5,  'step verbatim');

    my $single = Temporalio::Schedule::Range->new(start => 7);
    my $sp = $single->_to_proto;
    T2->is($sp->start, 7, 'single value start');
    T2->is($sp->end,   7, 'single value end defaults to start');
    T2->is($sp->step,  1, 'single value default step 1');

    my $back = Temporalio::Schedule::Range->_from_proto($p);
    T2->is($back->start, 0,  'round-trip start');
    T2->is($back->end,   30, 'round-trip end');
    T2->is($back->step,  5,  'round-trip step');
});

# ---------------------------------------------------------------------------
# Calendar: per-field default ranges injected (empty second != "never match").
# ---------------------------------------------------------------------------
T2->subtest('Calendar injects per-field default ranges' => sub {
    my $cal = Temporalio::Schedule::Calendar->new;    # all defaults
    my $p   = $cal->_to_proto;

    my $sec = $p->second;
    T2->is(scalar(@$sec), 1, 'second has one default range');
    T2->is($sec->[0]->start, 0, 'second default start 0');
    T2->is($sec->[0]->end,   0, 'second default end 0');

    my $dom = $p->day_of_month;
    T2->is($dom->[0]->start, 1,  'day_of_month default start 1');
    T2->is($dom->[0]->end,   31, 'day_of_month default end 31');

    my $mon = $p->month;
    T2->is($mon->[0]->start, 1,  'month default start 1');
    T2->is($mon->[0]->end,   12, 'month default end 12');

    my $dow = $p->day_of_week;
    T2->is($dow->[0]->start, 0, 'day_of_week default start 0');
    T2->is($dow->[0]->end,   6, 'day_of_week default end 6');

    my $year = $p->year;
    T2->is(scalar(@$year), 0, 'year stays empty (matches all years)');

    # An explicit field is NOT overridden by a default.
    my $explicit = Temporalio::Schedule::Calendar->new(
        hour => [ Temporalio::Schedule::Range->new(start => 9, end => 17) ]);
    my $ep = $explicit->_to_proto;
    T2->is($ep->hour->[0]->start, 9,  'explicit hour start kept');
    T2->is($ep->hour->[0]->end,   17, 'explicit hour end kept');
});

# ---------------------------------------------------------------------------
# Spec proto field remaps + start_time inclusive (rule 2).
# ---------------------------------------------------------------------------
T2->subtest('Spec field remaps and start_time' => sub {
    my $spec = Temporalio::Schedule::Spec->new(
        calendars        => [ Temporalio::Schedule::Calendar->new ],
        intervals        => [ Temporalio::Schedule::Interval->new(every => 3600) ],
        cron_expressions => [ '0 12 * * *' ],
        skip             => [ Temporalio::Schedule::Calendar->new ],
        start_at         => 1_700_000_000,
        end_at           => 1_700_003_600,
        jitter           => 30,
        time_zone_name   => 'US/Central',
    );
    my $p = $spec->_to_proto;

    T2->is(scalar(@{ $p->structured_calendar }), 1,
        'calendars -> structured_calendar');
    T2->is(scalar(@{ $p->interval }), 1, 'intervals -> interval');
    T2->is($p->cron_string->[0], '0 12 * * *', 'cron_expressions -> cron_string');
    T2->is(scalar(@{ $p->exclude_structured_calendar }), 1,
        'skip -> exclude_structured_calendar');
    T2->is($p->timezone_name, 'US/Central', 'time_zone_name -> timezone_name');
    T2->is($p->start_time->seconds, 1_700_000_000,
        'start_at -> start_time (inclusive, verbatim seconds)');
    T2->is($p->end_time->seconds, 1_700_003_600, 'end_at -> end_time');
    T2->is($p->jitter->seconds, 30, 'jitter seconds');

    # _from_proto leaves cron_expressions empty (server compiles them).
    my $back = Temporalio::Schedule::Spec->_from_proto($p);
    T2->is(scalar(@{ $back->cron_expressions }), 0,
        'from_proto cron_expressions left empty');
    T2->is($back->time_zone_name, 'US/Central', 'from_proto timezone');
    T2->is($back->start_at, 1_700_000_000, 'from_proto start_at');
});

# ---------------------------------------------------------------------------
# Interval: every -> interval, offset -> phase.
# ---------------------------------------------------------------------------
T2->subtest('Interval every/offset remap' => sub {
    my $iv = Temporalio::Schedule::Interval->new(every => 3600, offset => 1140);
    my $p  = $iv->_to_proto;
    T2->is($p->interval->seconds, 3600, 'every -> interval');
    T2->is($p->phase->seconds,    1140, 'offset -> phase');

    my $no_offset = Temporalio::Schedule::Interval->new(every => 60);
    my $np = $no_offset->_to_proto;
    T2->is($np->interval->seconds, 60, 'every with no offset');
    T2->ok(!defined $np->phase, 'phase absent when offset undef');
});

# ---------------------------------------------------------------------------
# State: note -> notes; Policy proto field is policies (in Schedule).
# ---------------------------------------------------------------------------
T2->subtest('State note->notes remap' => sub {
    my $state = Temporalio::Schedule::State->new(
        note => 'held', paused => 1, limited_actions => 1, remaining_actions => 3);
    my $p = $state->_to_proto;
    T2->is($p->notes, 'held', 'note -> notes');
    T2->is($p->paused, 1, 'paused');
    T2->is($p->limited_actions, 1, 'limited_actions');
    T2->is($p->remaining_actions, 3, 'remaining_actions');
});

# ---------------------------------------------------------------------------
# OverlapPolicy string -> enum.
# ---------------------------------------------------------------------------
T2->subtest('OverlapPolicy string->enum' => sub {
    my %expect = (
        unspecified => 0, skip => 1, buffer_one => 2, buffer_all => 3,
        cancel_other => 4, terminate_other => 5, allow_all => 6,
    );
    for my $name (sort keys %expect) {
        T2->is(Temporalio::Schedule::Policy::overlap_enum($name), $expect{$name},
            "overlap '$name' -> $expect{$name}");
    }
    my $bad = T2->dies(sub {
        Temporalio::Schedule::Policy::overlap_enum('nope');
    });
    T2->ok($bad && $bad->isa('Temporalio::Exception::Argument'),
        'unknown overlap -> Argument');

    my $pol = Temporalio::Schedule::Policy->new(overlap => 'buffer_one');
    my $pp  = $pol->_to_proto;
    T2->is($pp->overlap_policy, 2, 'Policy overlap_policy enum');
    T2->is($pp->catchup_window->seconds, 365 * 24 * 60 * 60,
        'default catchup_window 365 days');
});

# ---------------------------------------------------------------------------
# Schedule: policy -> policies; async _to_proto encodes the action.
# ---------------------------------------------------------------------------
T2->subtest('Schedule policy->policies + action encode' => sub {
    my $client = make_client;
    my $schedule = Temporalio::Schedule::Schedule->new(
        action => Temporalio::Schedule::Action::StartWorkflow->new(
            workflow => 'MyWorkflow', args => ['arg1'],
            id => 'sched-wf', task_queue => 'tq'),
        spec   => Temporalio::Schedule::Spec->new(
            intervals => [ Temporalio::Schedule::Interval->new(every => 3600) ]),
        policy => Temporalio::Schedule::Policy->new(overlap => 'buffer_one'),
        state  => Temporalio::Schedule::State->new(paused => 1),
    );
    my $p = $schedule->_to_proto($client)->get;

    T2->ok(defined $p->policies, 'policy -> policies (plural) field set');
    T2->is($p->policies->overlap_policy, 2, 'policies overlap');
    T2->is($p->state_->paused, 1, 'state paused');    # reader is state_ (collision)
    my $sw = $p->action->start_workflow;
    T2->is($sw->workflow_type->name, 'MyWorkflow', 'action workflow type');
    T2->is($sw->workflow_id, 'sched-wf', 'action workflow id');
    T2->is($sw->task_queue->name, 'tq', 'action task queue');
    T2->ok(defined $sw->input && @{ $sw->input->payloads } == 1,
        'action arg encoded to one payload');
});

# ---------------------------------------------------------------------------
# Action rejects workflow_id_reuse_policy / cron_schedule kwargs.
# ---------------------------------------------------------------------------
T2->subtest('Action rejects reuse/cron kwargs and requires fields' => sub {
    my $reuse = T2->dies(sub {
        Temporalio::Schedule::Action::StartWorkflow->new(
            workflow => 'W', id => 'i', task_queue => 'tq',
            workflow_id_reuse_policy => 'reject_duplicate');
    });
    T2->ok($reuse, 'workflow_id_reuse_policy kwarg dies');

    my $cron = T2->dies(sub {
        Temporalio::Schedule::Action::StartWorkflow->new(
            workflow => 'W', id => 'i', task_queue => 'tq',
            cron_schedule => '* * * * *');
    });
    T2->ok($cron, 'cron_schedule kwarg dies');

    my $no_id = T2->dies(sub {
        Temporalio::Schedule::Action::StartWorkflow->new(
            workflow => 'W', task_queue => 'tq');
    });
    T2->ok($no_id && $no_id->isa('Temporalio::Exception::Argument'),
        'missing id -> Argument');
});

# ---------------------------------------------------------------------------
# Backfill: start_at EXCLUSIVE / end_at inclusive (rule 3) -> proto verbatim.
# ---------------------------------------------------------------------------
T2->subtest('Backfill start exclusive / end inclusive' => sub {
    my $bf = Temporalio::Schedule::Backfill->new(
        start_at => 1_700_000_000, end_at => 1_700_003_600, overlap => 'allow_all');
    my $p = $bf->_to_proto;
    T2->is($p->start_time->seconds, 1_700_000_000,
        'backfill start_time (exclusive in semantics, verbatim seconds)');
    T2->is($p->end_time->seconds, 1_700_003_600, 'backfill end_time inclusive');
    T2->is($p->overlap_policy, 6, 'backfill overlap allow_all -> 6');
});

T2->done_testing;
