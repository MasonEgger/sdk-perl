# ABOUTME: Tests Temporalio::Workflow::Future (spec section 10.3): the
# ABOUTME: manually-resolved deterministic Future subclass that the workflow
# ABOUTME: runner drives imperatively (never via IO::Async). Covers manual
# ABOUTME: resolve running awaiting continuations synchronously, on_cancel
# ABOUTME: hooks firing in reverse-registration order, and is_workflow_future.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Temporalio::Workflow::Future ();

# Spec section 10.3: Temporalio::Workflow::Future is a subclass of the CPAN
# Future module, resolved by the runner (NOT by IO::Async timers). The runner
# calls ->done / ->fail imperatively from activation jobs; awaiting
# continuations (registered by Future::AsyncAwait await, i.e. on_ready
# callbacks) must run synchronously at resolve time so the deterministic pump
# can observe progress. on_cancel hooks fire in reverse-registration order on
# ->cancel. is_workflow_future is true so interceptors can distinguish these
# from ordinary Futures.

T2->subtest('is a Future subclass and is_workflow_future is true' => sub {
    my $f = Temporalio::Workflow::Future->new;
    T2->isa_ok($f, 'Future');
    T2->ok($f->is_workflow_future, 'is_workflow_future is true');
    T2->ok(!$f->is_ready, 'fresh future is pending');
});

T2->subtest('manual resolve runs awaiting continuations synchronously (done)' => sub {
    my $f = Temporalio::Workflow::Future->new;

    my @seen;
    $f->on_ready(sub ($ready) { push @seen, $ready->result });

    T2->is(\@seen, [], 'continuation has not run before resolve');

    $f->done('result-value');

    T2->ok($f->is_ready, 'future is ready after ->done');
    T2->is(\@seen, ['result-value'],
        'on_ready continuation ran synchronously during ->done');
    T2->is(scalar($f->result), 'result-value', 'result is the resolved value');
});

T2->subtest('manual resolve runs awaiting continuations synchronously (fail)' => sub {
    my $f = Temporalio::Workflow::Future->new;

    my @failures;
    $f->on_fail(sub (@f) { push @failures, $f[0] });

    $f->fail('boom\n');

    T2->ok($f->is_ready, 'future is ready after ->fail');
    T2->ok($f->is_failed, 'future is failed');
    T2->is(\@failures, ['boom\n'],
        'on_fail continuation ran synchronously during ->fail');
});

T2->subtest('on_cancel hooks fire in reverse-registration order on ->cancel' => sub {
    my $f = Temporalio::Workflow::Future->new;

    my @order;
    $f->on_cancel(sub { push @order, 'first' });
    $f->on_cancel(sub { push @order, 'second' });
    $f->on_cancel(sub { push @order, 'third' });

    T2->is(\@order, [], 'no cancel hook ran before ->cancel');

    $f->cancel;

    T2->ok($f->is_cancelled, 'future is cancelled');
    T2->is(\@order, ['third', 'second', 'first'],
        'on_cancel hooks fired in reverse-registration order');
});

T2->subtest('new() returns a same-class instance for chained futures' => sub {
    # Future's ->new is used internally to construct dependent futures; a
    # subclass must return its own class so the runner can keep driving them.
    my $f = Temporalio::Workflow::Future->new;
    my $g = $f->new;
    T2->isa_ok($g, 'Temporalio::Workflow::Future');
    T2->ok($g->is_workflow_future, 'derived future is also a workflow future');
});

T2->done_testing;
