# ABOUTME: R34/R61 port-strategy pins (findings T-flake / L29): DevServer passes
# ABOUTME: port 0 through the bridge, reads the bound target back from the start
# ABOUTME: callback, and carries no Net::EmptyPort dependency in any phase.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Find ();
use File::Spec ();
use FindBin ();
use IO::Async::Loop ();
use IO::Socket::INET ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Runtime ();
use Temporalio::Test::DevServer ();

# Code trace (finding T-flake / spec R34): the pre-fix Test/DevServer.pm picked
# a port with Net::EmptyPort::empty_port() (bind :0, read the kernel's pick,
# CLOSE the socket, return the number), then handed that number to sdk-core,
# which spawned the temporal CLI to bind it a moment later. Between the close
# and the CLI's bind the port sat free inside the kernel's outbound ephemeral
# range, so a parallel prove -j4 neighbor (or any outbound connection) could
# take it first: bind-failure and wrong-server flakes (the known updates.t
# flake). The fix passes port 0 through the bridge (TestServerOptions.port is
# documented "0 means default behavior" in the pinned C header) so sdk-core's
# own get_free_port picks the port (and parks it in TIME_WAIT so the kernel
# cannot re-issue it) and the ACTUAL bound endpoint comes back through the
# start callback's success_target. This file is the durable adaptation of the
# step-45 probe verify-45/memsafe-infra/emptyport_range.pl.
#
# Finding L29 (spec R61) closes with it: Net::EmptyPort was loaded at runtime
# by a lib/ module while sdk/cpanfile declared it test-phase only. The port fix
# removes the module entirely, so R61 collapses to deleting the dependency; the
# audit subtest below keeps every future Net::EmptyPort use honest about its
# cpanfile phase.

my $sdk_root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..'));

T2->subtest('the probe claim: a bind(:0) pick lands in the kernel ephemeral range' => sub {
    # This is the hazard the pre-fix code created: empty_port()'s no-args
    # branch takes exactly this bind(:0) pick and then FREES it, inside the
    # same range the kernel allocates outbound ports (and other bind(:0)
    # calls) from. sdk-core's get_free_port takes the same pick but reserves
    # it via a self-connect that leaves the port in TIME_WAIT, which is why
    # delegating the pick to core is race-free where the Perl-side pick was
    # not.
    my $range_file = '/proc/sys/net/ipv4/ip_local_port_range';
    T2->skip_all("$range_file not readable on this platform")
        unless -r $range_file;
    open my $fh, '<', $range_file or die "open $range_file: $!";
    my ($lo, $hi) = split ' ', scalar <$fh>;
    close $fh;

    my $sock = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Listen    => 1,
        Proto     => 'tcp',
    ) or die "bind :0 failed: $!";
    my $picked = $sock->sockport;
    $sock->close;

    T2->ok($picked >= $lo && $picked <= $hi,
        "the kernel's bind(:0) pick ($picked) falls inside the ephemeral "
      . "range $lo-$hi it also allocates outbound ports from");
});

T2->subtest('startup passes port 0 through the bridge and reads the bound target back (R34)' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $FAKE_HANDLE = 0xdead_beef;
    my $BOUND       = '127.0.0.1:34567';    # the core-reported bound endpoint

    # Wrap (not replace) the TestServerOptions record constructor to capture
    # the port DevServer hands to the bridge; spy issue_async so no bridge
    # call is ever issued and the start future is test-controlled.
    my $orig_new = Temporalio::Core::FFI::TestServerOptions->can('new');
    my @captured_ports;
    my @free_calls;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::TestServerOptions::new = sub {
        my ($class, %args) = @_;
        push @captured_ports, $args{port};
        return $orig_new->($class, %args);
    };
    local *Temporalio::Core::Callback::issue_async =
        sub ($class, $rt, $kind, $invoke) {
            my $f = $loop->new_future;
            if ($kind eq 'server_start') {
                $f->done({ handle => $FAKE_HANDLE, target => $BOUND });
            }
            else {    # server_shutdown, from the cleanup below
                $f->done(undef);
            }
            return $f;
        };
    local *Temporalio::Core::FFI::ephemeral_server_free =
        sub ($handle) { push @free_calls, $handle };
    use warnings 'redefine';

    my $server = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => '/bin/true',
    );

    T2->is(\@captured_ports, [0],
        'no port is picked Perl-side: 0 rides the bridge so sdk-core '
      . 'selects (and reserves) the free port itself');
    T2->is($server->target, $BOUND,
        'the server target is the bridge-reported bound endpoint, '
      . 'not a Perl-side pick');
    $server->shutdown;

    # An explicit caller-chosen port still passes through untouched.
    my $server2 = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => '/bin/true',
        port          => 7777,
    );
    T2->is($captured_ports[-1], 7777, 'an explicit port option passes through');
    $server2->shutdown;

    T2->is(\@free_calls, [$FAKE_HANDLE, $FAKE_HANDLE],
        'both synthetic handles were freed on the clean shutdown path');
    $runtime->shutdown;
});

T2->subtest('DevServer no longer loads Net::EmptyPort (R34 closes R61)' => sub {
    # The code-trace comments at the fixed port site still NAME the removed
    # module (evergreen history), so this matches load statements only.
    my $module = $INC{'Temporalio/Test/DevServer.pm'};
    T2->ok(defined $module, 'DevServer.pm located via %INC') or return;
    open my $fh, '<', $module or die "open $module: $!";
    my $source = do { local $/; <$fh> };
    close $fh;
    T2->unlike($source, qr/^\s*(?:use|require)\s+Net::EmptyPort\b/m,
        'no Net::EmptyPort load remains '
      . '(the select-then-free pick is gone)');
});

T2->subtest('cpanfile phase matches every Net::EmptyPort use site (R61 / finding L29)' => sub {
    # Finding L29: Test/DevServer.pm:12 loaded Net::EmptyPort at runtime (the
    # Test::* modules ship in the runtime dist) while sdk/cpanfile declared it
    # under on 'test' only, so a non-test consumer of Test::DevServer broke.
    # Audit contract, kept honest for any future reintroduction:
    #   - a use site under lib/ needs a runtime-phase declaration;
    #   - a use site under t/ or xt/ needs a test- (or runtime-) phase one;
    #   - a declaration with no use site at all is stale.
    my (@lib_uses, @test_uses);
    my sub scan ($dir, $into) {
        return unless -d $dir;
        File::Find::find({
            no_chdir => 1,
            wanted   => sub {
                return unless /\.(?:pm|pl|t)\z/;
                open my $fh, '<', $_ or die "open $_: $!";
                while (my $line = <$fh>) {
                    last if $line =~ /^__(?:END|DATA)__/;
                    push @$into, "$_:$." and last
                        if $line =~ /^\s*(?:use|require)\s+Net::EmptyPort\b/;
                }
                close $fh;
            },
        }, $dir);
    }
    scan(File::Spec->catdir($sdk_root, 'lib'), \@lib_uses);
    scan(File::Spec->catdir($sdk_root, $_), \@test_uses) for qw(t xt);

    # Minimal cpanfile phase parse: a requires/recommends line is runtime
    # phase at the top level and test phase inside an on 'test' block.
    my $cpanfile = File::Spec->catfile($sdk_root, 'cpanfile');
    open my $fh, '<', $cpanfile or die "open $cpanfile: $!";
    my ($phase, $runtime_decl, $test_decl) = ('runtime', 0, 0);
    while (my $line = <$fh>) {
        $phase = $1 if $line =~ /^on\s+'(\w+)'\s*=>/;
        $phase = 'runtime' if $line =~ /^\};/;
        if ($line =~ /^\s*(?:requires|recommends)\s+'Net::EmptyPort'/) {
            $runtime_decl = 1 if $phase eq 'runtime';
            $test_decl    = 1 if $phase eq 'test';
        }
    }
    close $fh;

    T2->ok(!(@lib_uses && !$runtime_decl),
        'every lib/ use site has a runtime-phase declaration')
        or T2->diag("lib/ use sites without a runtime-phase declaration:\n"
                  . join("\n", @lib_uses));
    T2->ok(!(@test_uses && !($test_decl || $runtime_decl)),
        'every t//xt/ use site has a test- or runtime-phase declaration')
        or T2->diag("t//xt/ use sites:\n" . join("\n", @test_uses));
    T2->ok(!(($runtime_decl || $test_decl) && !@lib_uses && !@test_uses),
        'no stale Net::EmptyPort declaration survives without a use site');
});

T2->done_testing;
