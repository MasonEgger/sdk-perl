# ABOUTME: R67 (finding A13): query's reject_condition maps Python-parity
# ABOUTME: named values (none/not_open/not_completed_cleanly) to the
# ABOUTME: QueryRejectCondition proto enum, keeps raw-number pass-through, and
# ABOUTME: raises the typed Argument error on an unknown name before any RPC.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Scalar::Util ();

use Temporalio::Client ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();

Temporalio::Core::Proto->load;

sub resolve { Temporalio::Core::Proto::resolve($_[0]) }

# ---------------------------------------------------------------------------
# The per-object _rpc_call mock registry from client_option_strictness.t: a
# real Client whose RPC layer is a scripted handler, so no live connection is
# ever touched.
# ---------------------------------------------------------------------------
our %MOCKS;
{
    no warnings 'redefine';
    my $orig = \&Temporalio::Client::_rpc_call;
    *Temporalio::Client::_rpc_call = sub {
        my ($self, $rpc, $request, %opts) = @_;
        if (my $mock = $MOCKS{ Scalar::Util::refaddr($self) }) {
            return $mock->($rpc, $request, %opts);
        }
        return $orig->($self, $rpc, $request, %opts);
    };
}

sub make_client {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-test',
        identity       => 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

sub payloads_of ($converter, @values) {
    my @p = $converter->to_payloads([@values])->get;
    return resolve('temporal.api.common.v1.Payloads')->new({ payloads => [@p] });
}

# Scripted QueryWorkflow responder; records every request it saw.
sub query_script ($client) {
    my @calls;
    my $conv = $client->data_converter;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request };
        return Future->done(
            resolve('temporal.api.workflowservice.v1.QueryWorkflowResponse')
                ->new({ query_result => payloads_of($conv, 'answer') }));
    };
    return \@calls;
}

sub caught ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

# ---------------------------------------------------------------------------
# Each Python-parity named value maps to its proto enum number in the emitted
# QueryWorkflowRequest (temporal.api.enums.v1.QueryRejectCondition, verified
# against sdk-python common.py QueryRejectCondition).
# ---------------------------------------------------------------------------
my %NAMED = (
    none                  => 1,    # QUERY_REJECT_CONDITION_NONE
    not_open              => 2,    # QUERY_REJECT_CONDITION_NOT_OPEN
    not_completed_cleanly => 3,    # QUERY_REJECT_CONDITION_NOT_COMPLETED_CLEANLY
);

T2->subtest('named reject_condition values map to the proto enum' => sub {
    for my $name (sort keys %NAMED) {
        my $client = make_client;
        my $calls  = query_script($client);
        my $h      = $client->get_workflow_handle('wf-1', run_id => 'run-1');
        my $answer = $h->query('q', [], reject_condition => $name)->get;
        T2->is($answer, 'answer', "'$name': query result decoded");
        T2->is($calls->[0]{request}->query_reject_condition, $NAMED{$name},
            "'$name' maps to $NAMED{$name} on the request");
    }
});

T2->subtest('raw proto number still passes through (regression)' => sub {
    my $client = make_client;
    my $calls  = query_script($client);
    my $h      = $client->get_workflow_handle('wf-1', run_id => 'run-1');
    $h->query('q', [], reject_condition => 2)->get;
    T2->is($calls->[0]{request}->query_reject_condition, 2,
        'numeric reject_condition carried verbatim');
});

T2->subtest('omitted reject_condition leaves the field unset' => sub {
    my $client = make_client;
    my $calls  = query_script($client);
    my $h      = $client->get_workflow_handle('wf-1', run_id => 'run-1');
    $h->query('q', [])->get;
    T2->is($calls->[0]{request}->query_reject_condition // 0, 0,
        'field stays at the proto default when the option is omitted');
});

T2->subtest('invalid value raises the typed argument error before any RPC' => sub {
    my $client = make_client;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub ($rpc, @) {
        return Future->fail(
            "unexpected RPC '$rpc': validation did not fire\n");
    };
    my $h   = $client->get_workflow_handle('wf-1', run_id => 'run-1');
    my $err = caught(sub { $h->query('q', [], reject_condition => 'bogus')->get });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        'bogus name raises Temporalio::Exception::Argument',
    ) or T2->diag('got: ' . ($err // 'no error'));
    my $msg = Scalar::Util::blessed($err) ? $err->message : ($err // '');
    T2->like($msg, qr/reject_condition/,
        'the error names the reject_condition option');
    T2->like($msg, qr/not_completed_cleanly/,
        'the error lists the valid names');
});

T2->done_testing;
