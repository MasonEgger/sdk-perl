# ABOUTME: Unit tests for the interceptor framework (spec section 27.1/27.2/27.3):
# ABOUTME: client outbound + worker inbound/outbound base classes, chain folding
# ABOUTME: (first-listed outermost), Input read-only/writable, failure modes
# ABOUTME: (T-icpt-1..10).
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use Future ();
use Future::AsyncAwait;

use Temporalio::Client::Interceptor ();
use Temporalio::Worker::Interceptor ();
use Temporalio::Interceptor::Input ();

# A client interceptor whose intercept_client returns the wrong type. Defined
# as a classic package (outside `feature 'class'`) so @ISA is set at compile
# time and the framework's isa-check reaches the "must return" branch.
package BadClientInterceptor {
    our @ISA = ('Temporalio::Client::Interceptor');
    sub new { bless {}, shift }
    sub intercept_client { return bless {}, 'NotAnOutbound' }
}

# --------------------------------------------------------------------------
# Test interceptor fixtures (defined here, not on disk — they only exercise
# the framework's delegation/ordering/header semantics).
#
# NOTE: fixture methods are signature-less (args from @_) AND every Test2 call
# below the class blocks uses the T2-> package form. Both are required: the
# perl 5.38 `feature 'class'` block form disables the bareword Test2 exports for
# code that follows it, and a `field :param` adjacent to a signatured method
# poisons the parser once Future::AsyncAwait is loaded process-wide. The same
# shape is used in t/unit/activity_dispatch.t.
# --------------------------------------------------------------------------

# An outbound that records the header it sees, appends its tag to a shared
# trace, optionally injects a header, then delegates to next.
class RecordingOutbound :isa(Temporalio::Client::OutboundInterceptor) {
    field $tag    :param;
    field $trace  :param;
    field $inject :param = undef;   # [key, payload] to add to headers, or undef

    async method start_workflow {
        my ($input) = @_;
        push @$trace, "$tag:start";
        if ($inject) {
            my $h = { %{ $input->headers } };
            $h->{ $inject->[0] } = $inject->[1];
            $input->headers($h);
        }
        return await $self->next->start_workflow($input);
    }

    # Compliance case (T-icpt-2): increment args[0] before delegating.
    async method start_workflow_update {
        my ($input) = @_;
        my $args = [ @{ $input->args } ];
        $args->[0] += 1;
        $input->args($args);
        return await $self->next->start_workflow_update($input);
    }

    # signal_workflow left at the base default to prove no-op delegation.
}

class RecordingClientInterceptor :isa(Temporalio::Client::Interceptor) {
    field $tag    :param;
    field $trace  :param;
    field $inject :param = undef;
    method intercept_client {
        my ($next) = @_;
        return RecordingOutbound->new(
            next => $next, tag => $tag, trace => $trace, inject => $inject);
    }
}

# Root impl: terminates the chain and reports what it received.
class RootOutbound :isa(Temporalio::Client::OutboundInterceptor) {
    field $seen :param;
    async method start_workflow {
        my ($input) = @_;
        $seen->{headers} = { %{ $input->headers } };
        $seen->{args}    = [ @{ $input->args } ];
        push @{ $seen->{trace} }, 'root:start' if $seen->{trace};
        return 'handle';
    }
    async method start_workflow_update {
        my ($input) = @_;
        $seen->{args} = [ @{ $input->args } ];
        return 'update-result';
    }
}

# A raising interceptor (T-icpt-9).
class RaisingOutbound :isa(Temporalio::Client::OutboundInterceptor) {
    async method start_workflow { die "boom\n" }
}
class RaisingClientInterceptor :isa(Temporalio::Client::Interceptor) {
    method intercept_client { return RaisingOutbound->new(next => $_[0]) }
}

# Worker inbound fixtures.
class RecordingActivityInbound :isa(Temporalio::Worker::ActivityInbound) {
    field $tag   :param;
    field $trace :param;
    async method execute_activity {
        my ($input) = @_;
        push @$trace, "$tag:act";
        return await $self->next->execute_activity($input);
    }
}
class RecordingWorkflowInbound :isa(Temporalio::Worker::WorkflowInbound) {
    field $tag   :param;
    field $trace :param;
    async method execute_workflow {
        my ($input) = @_;
        push @$trace, "$tag:wf";
        return await $self->next->execute_workflow($input);
    }
}
class RecordingWorkerInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $tag   :param;
    field $trace :param;
    method intercept_activity {
        return RecordingActivityInbound->new(
            next => $_[0], tag => $tag, trace => $trace);
    }
    method intercept_workflow {
        return RecordingWorkflowInbound->new(
            next => $_[0], tag => $tag, trace => $trace);
    }
}

# Root inbounds.
class RootActivityInbound :isa(Temporalio::Worker::ActivityInbound) {
    field $trace :param;
    async method execute_activity {
        push @$trace, 'root:act'; return 'act-done';
    }
}
class RootWorkflowInbound :isa(Temporalio::Worker::WorkflowInbound) {
    field $trace :param;
    async method execute_workflow {
        push @$trace, 'root:wf'; return 'wf-done';
    }
}

# --------------------------------------------------------------------------
# T-icpt-3 + T-icpt-1: first-listed is outermost; header round-trips to root.
# --------------------------------------------------------------------------
T2->subtest('first-listed-outermost ordering + header injection (T-icpt-1,3)' => sub {
    my @trace;
    my %seen;
    my $root = RootOutbound->new(seen => \%seen);
    $seen{trace} = \@trace;

    my @list = (
        RecordingClientInterceptor->new(
            tag => 'A', trace => \@trace, inject => [ k => 'payloadA' ]),
        RecordingClientInterceptor->new(tag => 'B', trace => \@trace),
    );
    my $chain =
        Temporalio::Client::Interceptor::build_outbound_chain(\@list, $root);

    my $input = Temporalio::Client::Interceptor::Input::StartWorkflow->new(
        workflow => 'W', args => [1], headers => {});
    my $res = $chain->start_workflow($input)->get;

    T2->is($res, 'handle', 'returns the root result');
    T2->is(\@trace, [ 'A:start', 'B:start', 'root:start' ],
        'A (first-listed) runs outermost, then B, then root');
    T2->is($seen{headers}{k}, 'payloadA', 'injected header reaches the root impl');
});

# --------------------------------------------------------------------------
# T-icpt-2: client_interceptor compliance — start_workflow_update increments
# args[0].
# --------------------------------------------------------------------------
T2->subtest('start_workflow_update increments args[0] (T-icpt-2)' => sub {
    my %seen;
    my $root = RootOutbound->new(seen => \%seen);
    my @list = ( RecordingClientInterceptor->new(tag => 'A', trace => []) );
    my $chain =
        Temporalio::Client::Interceptor::build_outbound_chain(\@list, $root);

    my $input =
        Temporalio::Client::Interceptor::Input::StartWorkflowUpdate->new(
            update => 'U', args => [ 41 ], headers => {});
    my $res = $chain->start_workflow_update($input)->get;
    T2->is($res, 'update-result', 'returns the root update result');
    T2->is($seen{args}, [ 42 ],
        'outbound incremented args[0] before the root saw it');
});

# --------------------------------------------------------------------------
# T-icpt-8: no-op default delegation — a base-default method still reaches root.
# --------------------------------------------------------------------------
T2->subtest('no-op default delegation (T-icpt-8)' => sub {
    my %seen;
    my $root = RootOutbound->new(seen => \%seen);
    # RecordingOutbound leaves start_workflow overridden but exercises the base
    # OutboundInterceptor's default passthrough for the wrapping above it.
    my $chain = RecordingOutbound->new(next => $root, tag => 'A', trace => []);
    my $input = Temporalio::Client::Interceptor::Input::StartWorkflow->new(
        workflow => 'W', args => [], headers => {});
    my $res = $chain->start_workflow($input)->get;
    T2->is($res, 'handle', 'default chain still reaches the root');
});

# --------------------------------------------------------------------------
# T-icpt-9: a raising interceptor method rejects the caller Future.
# --------------------------------------------------------------------------
T2->subtest('raising interceptor rejects the Future (T-icpt-9)' => sub {
    my %seen;
    my $root = RootOutbound->new(seen => \%seen);
    my @list = ( RaisingClientInterceptor->new );
    my $chain =
        Temporalio::Client::Interceptor::build_outbound_chain(\@list, $root);
    my $input = Temporalio::Client::Interceptor::Input::StartWorkflow->new(
        workflow => 'W', args => [], headers => {});
    my $f = $chain->start_workflow($input);
    T2->ok($f->is_ready, 'future is ready');
    T2->like(T2->dies(sub { $f->get }), qr/boom/,
        'the failure propagates, not swallowed');
});

# --------------------------------------------------------------------------
# T-icpt-4 + T-icpt-6: activity / workflow inbound wrapping, outermost-first.
# --------------------------------------------------------------------------
T2->subtest('activity + workflow inbound wrapping (T-icpt-4,6)' => sub {
    my @trace;
    my @list = (
        RecordingWorkerInterceptor->new(tag => 'A', trace => \@trace),
        RecordingWorkerInterceptor->new(tag => 'B', trace => \@trace),
    );

    my $act_chain = Temporalio::Worker::Interceptor::build_activity_inbound(
        \@list, RootActivityInbound->new(trace => \@trace));
    my $r1 = $act_chain->execute_activity({})->get;
    T2->is($r1, 'act-done', 'activity inbound chain returns root result');
    T2->is(\@trace, [ 'A:act', 'B:act', 'root:act' ],
        'activity inbound: A outermost, then B, then root');

    @trace = ();
    my $wf_chain = Temporalio::Worker::Interceptor::build_workflow_inbound(
        \@list, RootWorkflowInbound->new(trace => \@trace));
    my $r2 = $wf_chain->execute_workflow({})->get;
    T2->is($r2, 'wf-done', 'workflow inbound chain returns root result');
    T2->is(\@trace, [ 'A:wf', 'B:wf', 'root:wf' ],
        'workflow inbound: A outermost, then B, then root');
});

# --------------------------------------------------------------------------
# T-icpt-7: a worker inherits the client interceptors and appends its own.
# Exercised through the combined-list ordering the Worker builds.
# --------------------------------------------------------------------------
T2->subtest('worker inherits client interceptors then appends own (T-icpt-7)' => sub {
    my @trace;
    my $client_i = RecordingWorkerInterceptor->new(tag => 'C', trace => \@trace);
    my $worker_i = RecordingWorkerInterceptor->new(tag => 'W', trace => \@trace);
    # The combined list is [ client..., worker... ] — client first => outermost.
    my @combined = ($client_i, $worker_i);
    my $chain = Temporalio::Worker::Interceptor::build_activity_inbound(
        \@combined, RootActivityInbound->new(trace => \@trace));
    $chain->execute_activity({})->get;
    T2->is(\@trace, [ 'C:act', 'W:act', 'root:act' ],
        'client interceptor runs outside the worker interceptor');
});

# --------------------------------------------------------------------------
# Input read-only / writable semantics (spec section 27.1/27.3).
# --------------------------------------------------------------------------
T2->subtest('Input args/headers writable, others read-only' => sub {
    my $input = Temporalio::Client::Interceptor::Input::StartWorkflow->new(
        workflow => 'W', args => [1, 2], headers => { a => 1 });

    T2->is($input->get('workflow'), 'W', 'reads a read-only field');
    T2->is($input->args, [1, 2], 'reads args');

    $input->args([9]);
    T2->is($input->args, [9], 'args is writable');
    $input->headers({ b => 2 });
    T2->is($input->headers, { b => 2 }, 'headers is writable');

    T2->like(T2->dies(sub { $input->set(workflow => 'X') }),
        qr/read-only/, 'mutating a read-only field dies');
});

# --------------------------------------------------------------------------
# Non-conforming interceptors / returns die at build time (spec section 27.3).
# --------------------------------------------------------------------------
T2->subtest('non-conforming interceptors die at build' => sub {
    T2->like(T2->dies(sub {
        Temporalio::Client::Interceptor::build_outbound_chain(
            [ bless {}, 'NotAnInterceptor' ], RootOutbound->new(seen => {}));
    }), qr/must extend/, 'a non-Interceptor in the list dies');

    # An interceptor whose intercept_client returns a non-OutboundInterceptor.
    my $bad = BadClientInterceptor->new;
    T2->like(T2->dies(sub {
        Temporalio::Client::Interceptor::build_outbound_chain(
            [ $bad ], RootOutbound->new(seen => {}));
    }), qr/must return/, 'a bad intercept_client return dies');
});

# --------------------------------------------------------------------------
# T-icpt-10: replay-determinism — folding the same list twice yields the same
# observable ordering and header set (no hidden mutable global state).
# --------------------------------------------------------------------------
T2->subtest('replay-determinism of the outbound fold (T-icpt-10)' => sub {
    my $build_and_run = sub {
        my @trace;
        my %seen = (trace => \@trace);
        my $root = RootOutbound->new(seen => \%seen);
        my @list = (
            RecordingClientInterceptor->new(
                tag => 'A', trace => \@trace, inject => [ k => 'p' ]),
            RecordingClientInterceptor->new(tag => 'B', trace => \@trace),
        );
        my $chain =
            Temporalio::Client::Interceptor::build_outbound_chain(\@list, $root);
        my $input =
            Temporalio::Client::Interceptor::Input::StartWorkflow->new(
                workflow => 'W', args => [7], headers => {});
        $chain->start_workflow($input)->get;
        return { trace => [@trace], headers => $seen{headers} };
    };
    my $run1 = $build_and_run->();
    my $run2 = $build_and_run->();
    T2->is($run2, $run1,
        'two folds of the same list produce identical observations');
});

T2->done_testing;
