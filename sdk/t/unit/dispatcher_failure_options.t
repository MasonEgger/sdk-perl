# ABOUTME: Spec R14+R15 (findings A1/ADJ2): workflow_failure_exception_types and
# ABOUTME: nondeterminism_as_workflow_fail must reach LIVE Runners through the
# ABOUTME: Worker -> WorkflowDispatcher -> Runner plumbing, NOT core's
# ABOUTME: per-workflow-TYPE field, where exception class names were misrouted.
#
# Defect trace (finding A1, verified pre-fix): Worker.pm packed
# workflow_failure_exception_types (Perl EXCEPTION class names) into core's
# nondeterminism_as_workflow_fail_for_types, which core interprets as WORKFLOW
# TYPE names (sdk-python derives that set from per-definition
# failure_exception_types, _workflow.py nondeterminism_as_workflow_fail_for_types).
# Neither option was passed to the live WorkflowDispatcher, so live Runners ran
# with defaults ([] / 0) while the replay harness (Test/WorkflowReplay.pm)
# threaded both correctly: live/replay divergence (finding ADJ2 for the
# boolean).
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Temporalio::Converter::Data ();
use Temporalio::Converter::Payload ();
use Temporalio::Core::FFI ();
use Temporalio::Core::Proto;
use Temporalio::Worker ();
use Temporalio::Worker::WorkflowRegistry ();
use Temporalio::Worker::WorkflowDispatcher ();

my $Activation = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_activation.WorkflowActivation');

my $PC = Temporalio::Converter::Payload->default;

my $TYPES = ['WfDef::CustomError'];

# A client fake rich enough for Worker construction and dispatcher building:
# the Worker reads namespace + identity during option building and
# data_converter + namespace when building the workflow dispatcher.
class FakeClient {
    field $namespace :param = 'default';
    field $identity  :param = 'pid@host';
    field $data_converter = Temporalio::Converter::Data->new;
    method namespace      { $namespace }
    method identity       { $identity }
    method data_converter { $data_converter }
}

sub init_activation () {
    return $Activation->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'execute',
                arguments     => [ $PC->to_payload(1) ],
            } },
        ],
    });
}

# ---------------------------------------------------------------------------
# The dispatcher -> Runner hop: a live-path dispatcher constructed with both
# options hands them to the Runner it builds for a run (spec R14+R15
# acceptance: "constructs a live-path dispatcher and asserts the Runner
# receives the configured types" + "the R14 plumbing test also asserts this
# flag arrives").
# ---------------------------------------------------------------------------
T2->subtest('live dispatcher threads both options into its Runner (A1/ADJ2)' => sub {
    my $dispatcher = Temporalio::Worker::WorkflowDispatcher->new(
        registry => Temporalio::Worker::WorkflowRegistry->new(
            workflows => ['WfDef::Plain']),
        data_converter                   => Temporalio::Converter::Data->new,
        task_queue                       => 'demo',
        workflow_failure_exception_types => $TYPES,
        nondeterminism_as_workflow_fail  => 1,
        completer                        => sub ($bytes) { Future->done },
    );

    $dispatcher->dispatch_task(init_activation()->encode)->get;

    my $runner = $dispatcher->runner('r1');
    T2->ok(defined $runner, 'the run has a cached live Runner');
    return unless defined $runner;

    T2->is($runner->workflow_failure_exception_types, $TYPES,
        'workflow_failure_exception_types arrived at the live Runner (R14)');
    T2->ok($runner->nondeterminism_as_workflow_fail,
        'nondeterminism_as_workflow_fail arrived at the live Runner (R15)');
});

# ---------------------------------------------------------------------------
# The Worker -> dispatcher hop: Worker->new kwargs flow into the workflow
# dispatcher it builds, with the SAME key names the replay harness uses
# (live/replay parity, Test/WorkflowReplay.pm).
# ---------------------------------------------------------------------------
T2->subtest('Worker threads both options into its workflow dispatcher' => sub {
    my $worker = Temporalio::Worker->new(
        client                           => FakeClient->new,
        task_queue                       => 'demo',
        workflows                        => ['WfDef::Plain'],
        workflow_failure_exception_types => $TYPES,
        nondeterminism_as_workflow_fail  => 1,
    );
    my $dispatcher = $worker->_build_workflow_dispatcher;

    T2->is($dispatcher->workflow_failure_exception_types, $TYPES,
        'Worker passed workflow_failure_exception_types to the dispatcher');
    T2->ok($dispatcher->nondeterminism_as_workflow_fail,
        'Worker passed nondeterminism_as_workflow_fail to the dispatcher');
});

# ---------------------------------------------------------------------------
# The core side of finding A1: exception CLASS names must NOT land in core's
# nondeterminism_as_workflow_fail_for_types (a set of workflow TYPE names;
# sdk-python fills it from per-definition failure_exception_types, a surface
# this SDK does not expose, so it stays empty). The worker-level BOOLEAN still
# feeds core's nondeterminism_as_workflow_fail so core's own replayer honors
# it.
# ---------------------------------------------------------------------------
T2->subtest('core options no longer carry exception classes as workflow types' => sub {
    my $worker = Temporalio::Worker->new(
        client                           => FakeClient->new,
        task_queue                       => 'demo',
        workflows                        => ['WfDef::Plain'],
        workflow_failure_exception_types => $TYPES,
        nondeterminism_as_workflow_fail  => 1,
    );
    my $keep = [];
    my $raw  = Temporalio::Core::FFI::debug_worker_options(
        $worker->_build_worker_options($keep));
    defined $raw or T2->bail_out('debug_worker_options returned NULL');
    my $summary = Temporalio::Core::FFI::ffi()->cast('opaque' => 'string', $raw);
    Temporalio::Core::FFI::string_free($raw);
    my %echoed =
        map { my ($k, $v) = split /=/, $_, 2; ($k => $v) }
        split /\n/, $summary;

    T2->is($echoed{nondeterminism_as_workflow_fail}, 'true',
        'the boolean still reaches core (its replayer honors it)');
    T2->is($echoed{nondeterminism_as_workflow_fail_for_types}, '[]',
        'exception classes are NOT misrouted into core\'s workflow-TYPE field');
});

T2->done_testing;
