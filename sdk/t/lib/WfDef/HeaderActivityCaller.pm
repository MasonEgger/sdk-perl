# ABOUTME: Fixture workflow that schedules one activity passing an ALREADY-Payload
# ABOUTME: header value (as a context-propagation interceptor would, per the
# ABOUTME: sdk-python Str=>Payload header contract). Drives the #10 GAP B
# ABOUTME: outbound double-encode repro: schedule_activity must pass the Payload
# ABOUTME: through, not run it back through to_payload.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Converter::Payload;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run builds a header VALUE that is already a temporal.api.common.v1.Payload
# (a single-encoded 'rid-act' via the default payload converter — pure,
# deterministic JSON encoding, legal in workflow code) and forwards it on the
# execute_activity headers map. This mirrors context propagation, whose
# workflow-inbound hook reads the start headers as Payloads (#10/B11) and
# forwards them onward as Payloads. schedule_activity therefore receives an
# already-Payload header value; before the #10 GAP B fix it ran that value back
# through to_payload, double-encoding it.
class WfDef::HeaderActivityCaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($name = 'Bob') {
        my $pc = Temporalio::Converter::Payload->default;
        my $header_payload = $pc->to_payload('rid-act');
        my $greeting = await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => [$name],
            start_to_close_timeout => 60,
            headers                => { _request_id => $header_payload },
        );
        return "got: $greeting";
    }
}

1;
