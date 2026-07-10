# ABOUTME: Shared harness for the R7 codec-boundary replay tests: drives a real
# ABOUTME: Worker::WorkflowDispatcher with a TestCodec::Marker data converter.
use v5.38;
use warnings;

use Future ();

use Temporalio::Converter::Data ();
use Temporalio::Converter::Payload ();
use Temporalio::Core::Proto ();
use Temporalio::Payload ();
use Temporalio::Worker::WorkflowDispatcher ();
use Temporalio::Worker::WorkflowRegistry ();

use TestCodec::Marker;

# Unlike Temporalio::Test::WorkflowReplay (which drives a Runner directly and
# so never crosses the worker codec boundary), this harness dispatches through
# a real Temporalio::Worker::WorkflowDispatcher built over a data converter
# whose codec chain is a single TestCodec::Marker — exactly the seam spec R7
# requires the per-surface tests to exercise. Plain package (not `class`):
# only one `class :isa(...)` parses per file under Future::AsyncAwait
# (.ai-sessions/lessons.md) and the test files hold theirs in reserve.
package CodecBoundary;

my $Activation = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_activation.WorkflowActivation');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.workflow_completion.WorkflowActivationCompletion');
my $PC = Temporalio::Converter::Payload->default;

sub new ($class, %args) {
    my $codec = TestCodec::Marker->new;
    my $dc    = Temporalio::Converter::Data->new(payload_codecs => [$codec]);
    my $completions = [];
    my $dispatcher  = Temporalio::Worker::WorkflowDispatcher->new(
        registry => Temporalio::Worker::WorkflowRegistry->new(
            workflows => $args{workflows}),
        data_converter => $dc,
        task_queue     => 'codec-boundary',
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
    );
    return bless {
        codec       => $codec,
        dc          => $dc,
        dispatcher  => $dispatcher,
        completions => $completions,
    }, $class;
}

sub codec      ($self) { return $self->{codec} }
sub dc         ($self) { return $self->{dc} }
sub dispatcher ($self) { return $self->{dispatcher} }

# dispatch($run_id, \@jobs, %opt) -> the decoded WorkflowActivationCompletion
# for this activation. Jobs are the oneof-tagged hashref form; the activation
# is serialized exactly as core hands it to the worker. Activations resolve
# synchronously (the Runner drives workflow Futures imperatively), so ->get
# pumps the dispatch future to completion.
sub dispatch ($self, $run_id, $jobs, %opt) {
    my $bytes = $Activation->new({
        run_id    => $run_id,
        timestamp => { seconds => $opt{seconds} // 100 },
        jobs      => $jobs,
    })->encode;
    $self->{dispatcher}->dispatch_task($bytes)->get;
    return $Completion->decode($self->{completions}[-1]);
}

# The WorkflowCommand list of a successful completion (empty when failed).
sub commands_of ($self, $completion) {
    my $success = $completion->successful;
    return () unless defined $success;
    return ($success->commands // [])->@*;
}

# The first command of the given oneof variant, or undef.
sub command_of ($self, $completion, $variant) {
    my ($hit) = grep { ($_->which_variant // '') eq $variant }
        $self->commands_of($completion);
    return $hit;
}

# --- payload builders (inbound activations) --------------------------------

# A marker-WRAPPED payload for $value, as core would deliver it after a
# codec-using client encoded it: convert then run the codec chain.
sub marked_payload ($self, $value) {
    my @payloads = $self->{dc}->to_payloads([$value])->get;
    return $payloads[0];
}

# A bare (unwrapped) payload for $value — what codec-free fields carry.
sub plain_payload ($self, $value) { return $PC->to_payload($value) }

# --- payload assertions helpers (outbound completions) ---------------------

# True when $payload carries the marker codec's wrapper encoding.
sub is_marked ($payload) {
    return (($payload->metadata // {})->{encoding} // '')
        eq 'binary/codec-marker';
}

# The Perl value inside a marker-wrapped payload (unwrap, then convert).
sub marked_value ($payload) {
    return $PC->from_payload(
        Temporalio::Payload->decode($payload->data // ''));
}

# The Perl value of a bare payload.
sub plain_value ($payload) { return $PC->from_payload($payload) }

1;
