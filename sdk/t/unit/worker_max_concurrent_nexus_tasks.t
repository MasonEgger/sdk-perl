# ABOUTME: Unit tests for the max_concurrent_nexus_tasks worker kwarg (R80,
# ABOUTME: parity worker finding 1): N packs FixedSize(N) into the synthesized
# ABOUTME: fixed tuner's nexus pool, unset keeps 100, and passing it alongside
# ABOUTME: tuner raises the mutual-exclusion Argument error.
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Scalar::Util ();
use Temporalio::Core::FFI ();
use Temporalio::Worker ();
use Temporalio::Worker::Tuner ();

# Same construction-only fake as worker_new.t: the Worker reads namespace +
# identity off the client while building WorkerOptions; no live connection.
class FakeClient {
    field $namespace :param = 'default';
    field $identity  :param = 'pid@host';
    method namespace { $namespace }
    method identity  { $identity }
}

# Echo the WorkerOptions struct through the shim debug function (the P0.10
# path shared with worker_new.t): parse the field=value summary into a hash.
sub echo_options ($ptr) {
    my $raw = Temporalio::Core::FFI::debug_worker_options($ptr);
    defined $raw or T2->bail_out('debug_worker_options returned NULL');
    my $summary = Temporalio::Core::FFI::ffi()->cast('opaque' => 'string', $raw);
    Temporalio::Core::FFI::string_free($raw);
    return {
        map { my ($k, $v) = split /=/, $_, 2; ($k => $v) }
        split /\n/, $summary,
    };
}

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub nexus_supplier_for (%kwargs) {
    my $worker = Temporalio::Worker->new(
        client     => FakeClient->new,
        task_queue => 'tq-nexus',
        %kwargs,
    );
    my $keep = [];
    my $echoed = echo_options($worker->_build_worker_options($keep));
    return $echoed->{'tuner.nexus_task_slot_supplier'};
}

# Python parity (_worker.py:118, :545-563 at the audited revision;
# plan cites the same block as :129-133): max_concurrent_nexus_tasks feeds
# WorkerTuner.create_fixed(nexus_slots=N).
T2->subtest('max_concurrent_nexus_tasks => N packs FixedSize(N)' => sub {
    T2->is(nexus_supplier_for(max_concurrent_nexus_tasks => 17),
        'FixedSize(17)',
        'max_concurrent_nexus_tasks -> nexus FixedSize supplier of N');
});

# _tuning.py:344-363: any unspecified slot count defaults to 100.
T2->subtest('unset kwarg keeps the FixedSize(100) default' => sub {
    T2->is(nexus_supplier_for(),
        'FixedSize(100)',
        'no kwarg -> nexus FixedSize(100) default');
});

# _worker.py:545-557: max_concurrent_nexus_tasks joins the tuner
# mutual-exclusion set alongside the other three max_concurrent_* kwargs.
T2->subtest('max_concurrent_nexus_tasks + tuner is mutually exclusive' => sub {
    my $tuner = Temporalio::Worker::Tuner->create_fixed(
        workflow_slots => 1, activity_slots => 1,
        local_activity_slots => 1, nexus_task_slots => 1);
    my $err = exception_from(sub {
        Temporalio::Worker->new(
            client     => FakeClient->new,
            task_queue => 'tq-nexus',
            tuner      => $tuner,
            max_concurrent_nexus_tasks => 5,
        );
    });
    T2->isa_ok($err, ['Temporalio::Exception::Argument'],
        'tuner + max_concurrent_nexus_tasks raises Argument');
    # Pin the mutual-exclusion message (not the unrecognised-parameter
    # fallback, which would also carry the kwarg name).
    T2->like("$err", qr/mutually.*max_concurrent_nexus_tasks/s,
        'message is the mutual-exclusion error naming the kwarg')
        if Scalar::Util::blessed($err);
});

T2->done_testing;
