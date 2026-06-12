# ABOUTME: Tests Temporalio::Core::FFI: module load + wrapper-sub symbol table
# ABOUTME: (T-ffi-1), runtime_new/free round-trip (T-ffi-2), load diagnostics (T-ffi-3).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Basename qw(dirname);
use File::Spec     ();
use File::Temp     ();

# Spec section 4.1: one process-wide FFI::Platypus (api => 2) loading both
# the sdk-core-c-bridge and temporalio-perl-bridge cdylibs, with wrapper
# subs renamed to drop the temporal_core_ / temporalio_perl_bridge_ prefix.

# The Phase-0 attach set (plan P0.6): four c-bridge lifecycle functions,
# the shim queue/user_data functions, and the six trampoline ptr accessors.
my @phase0_wrappers = qw(
    runtime_new
    runtime_free
    byte_array_free
    cancellation_token_new
    cancellation_token_cancel
    cancellation_token_free
    queue_new
    queue_free
    queue_drain
    user_data_new
    worker_poll_callback_ptr
    worker_callback_ptr
    client_connect_callback_ptr
    client_rpc_call_callback_ptr
    ephemeral_server_start_callback_ptr
    ephemeral_server_shutdown_callback_ptr
);

T2->subtest('module loads and wrapper subs exist (T-ffi-1)' => sub {
    my $loaded = eval { require Temporalio::Core::FFI; 1 };
    T2->ok($loaded, 'use Temporalio::Core::FFI succeeds') or T2->diag($@);

    for my $name (@phase0_wrappers) {
        no strict 'refs';
        T2->ok(defined &{"Temporalio::Core::FFI::$name"},
            "wrapper sub $name is in the symbol table");
    }
});

T2->subtest('runtime_new/runtime_free round-trip (T-ffi-2)' => sub {
    # Default options: NULL telemetry, heartbeat disabled (0 millis).
    my $options = Temporalio::Core::FFI::RuntimeOptions->new(
        telemetry                         => undef,
        worker_heartbeat_interval_millis  => 0,
    );

    my $result = Temporalio::Core::FFI::runtime_new($options);
    T2->isa_ok($result, 'Temporalio::Core::FFI::RuntimeOrFail');
    # Assign accessors to lexicals first: record accessors return an empty
    # list for NULL in list context, which would shift T2 method args.
    my $fail = $result->fail;
    T2->is($fail, undef, 'fail pointer is NULL on success');
    my $runtime = $result->runtime;
    T2->ok(defined $runtime, 'runtime pointer is non-NULL');

    Temporalio::Core::FFI::runtime_free($runtime);
    T2->pass('runtime_free returned without crashing');
});

T2->subtest('load failure diagnostic names the attempted path (T-ffi-3)' => sub {
    # Run in a subprocess with both Alien modules masked by stubs whose
    # dynamic_libs point at a nonexistent library.
    my $lib_dir = File::Spec->rel2abs(
        File::Spec->catdir(dirname(__FILE__), '..', '..', 'lib'));

    my $bogus = '/nonexistent/libbogus-temporalio.so';
    my $child = File::Temp->new(SUFFIX => '.pl');
    print {$child} <<"EOS";
use v5.38;
BEGIN {
    \$INC{'Alien/Temporalio/Core.pm'}       = 'masked';
    \$INC{'Alien/Temporalio/PerlBridge.pm'} = 'masked';
}
sub Alien::Temporalio::Core::dynamic_libs       { '$bogus' }
sub Alien::Temporalio::PerlBridge::dynamic_libs { '/nonexistent/libbogus-bridge.so' }
require Temporalio::Core::FFI;
EOS
    close $child or T2->bail_out("cannot write child script: $!");

    my $out  = qx{"$^X" "-I$lib_dir" "$child" 2>&1};
    my $code = $? >> 8;

    T2->ok($code != 0, 'module load fails when the library path is bogus');
    T2->like($out, qr/\Q$bogus\E/, 'diagnostic includes the attempted path');
});

T2->done_testing;
