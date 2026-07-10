# ABOUTME: R7 codec-boundary replay test (spec R7, finding R6): update input
# ABOUTME: payloads on a DoUpdate job are codec-decoded before the handler runs.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use CodecBoundary ();

# Surface: DoUpdate.input (inbound decode). A configured codec (here the
# TestCodec::Marker wrapper) encodes the update input on the client; the
# worker boundary must decode it BEFORE the :Update handler runs, or the bare
# payload converter sees the wrapper encoding and dies (silently-defeated
# encryption, finding R6). DoUpdate carries no search attributes, so no SA
# negative on this surface.
T2->subtest('update input is codec-decoded before the handler runs' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::UpdateCounter']);

    # Init parks the body on its long timer.
    $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'UpdateCounter',
            arguments     => [],
        } },
    ]);

    # The update input payload arrives codec-wrapped, as core delivers it.
    my $completion = $cb->dispatch('r1', [
        { do_update => {
            id                   => 'u-1',
            protocol_instance_id => 'pi-1',
            name                 => 'add',
            input                => [ $cb->marked_payload(5) ],
            run_validator        => 1,
        } },
    ], seconds => 101);

    my @ur = grep { ($_->which_variant // '') eq 'update_response' }
        $cb->commands_of($completion);
    T2->is(scalar @ur, 2, 'accepted + completed update responses emitted');
    T2->is($ur[0]->update_response->which_response, 'accepted',
        'the update was accepted (validator saw the DECODED input)');
    T2->is($ur[1]->update_response->which_response, 'completed',
        'the update completed (handler saw the DECODED input)');

    # The handler returned the running total (5): the input reached it as the
    # decoded Perl value, not the codec wrapper.
    my $result = $ur[1]->update_response->completed;
    T2->ok(CodecBoundary::is_marked($result),
        'the update response payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($result), 5,
        'the handler computed with the decoded update input');

    # The boundary handed the wrapped input payload to the codec chain.
    T2->ok((grep { ($_->data // '') eq '5' } $cb->codec->decoded->@*),
        'the codec decoded the update input payload at the worker boundary');
});

T2->done_testing;
