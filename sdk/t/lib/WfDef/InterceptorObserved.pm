# ABOUTME: Fixture workflow exercising every workflow-inbound entry point —
# ABOUTME: :Run, :Signal, :Query, :Update — so one activation drives the full
# ABOUTME: inbound interceptor chain (#10 C-ICEPT, worker_inbound_interceptor.t).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks on a never-true wait_condition so the run stays open within the
# activation: the signal, update, and query jobs are all observed against a live
# instance in the same activation. State the handlers mutate is returned by the
# query so the through-chain dispatch is verifiable end to end.
class WfDef::InterceptorObserved :isa(Temporalio::Workflow::Definition) {
    field $total    = 0;
    field @signals;

    async method run :Run('InterceptorObserved') () {
        await Temporalio::Workflow::wait_condition(sub { 0 });
        return 'done';
    }

    method on_poke :Signal('poke') ($value) {
        push @signals, $value;
        return;
    }

    method get_total :Query('total') () {
        return $total;
    }

    method add :Update('add') ($delta) {
        $total += $delta;
        return $total;
    }
}

1;
