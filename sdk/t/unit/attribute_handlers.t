# ABOUTME: Regression test for the four Attribute::Handlers x feature 'class'
# constraints from spec section 10.1, ported from the t/spike/ proofs.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Temp ();
use File::Path qw(make_path);

# The SDK's workflow attribute surface (:Run/:Signal/:Query/:Update) depends
# on four empirically verified Perl behaviors (spec section 10.1). The
# runnable spike proofs live in t/spike/; this test guards against Perl
# version regressions. Distinct AttrSpike::* namespaces are used so nothing
# here collides with the real Temporalio::Workflow::Definition.

# Constraint 1: the base class consumed by :isa must itself be declared with
# 'class' — a plain-package base is rejected at compile time.
T2->subtest('constraint 1: base must be declared with class, not package' => sub {
    my $ok = eval q{
        use feature 'class';
        no warnings 'experimental::class';
        package AttrSpike::PlainBase {
            use Attribute::Handlers;
            sub Signal :ATTR(CODE,BEGIN) {}
        }
        class AttrSpike::PlainChild :isa(AttrSpike::PlainBase) {
            method m :Signal('x') ($v) {}
        }
        1;
    };
    T2->ok(!$ok, 'plain-package base fails to compile under :isa');
    T2->like(
        $@,
        qr/:isa attribute requires a class but "AttrSpike::PlainBase" is not one/,
        'diagnostic names the non-class base',
    );
});

# Constraint 2: :ATTR handlers must live in the inheritance chain. Importing
# Attribute::Handlers machinery from an unrelated package does not register
# the attribute for the class.
T2->subtest('constraint 2: handlers must live in the inheritance chain' => sub {
    my $ok = eval q{
        use feature 'class';
        no warnings 'experimental::class';
        package AttrSpike::Outside {
            use Attribute::Handlers;
            sub Signal :ATTR(CODE,BEGIN) {}
        }
        class AttrSpike::OrphanWF {
            BEGIN { AttrSpike::Outside->import; }
            method m :Signal('x') ($v) {}
        }
        1;
    };
    T2->ok(!$ok, 'out-of-chain handler fails to compile');
    T2->like(
        $@,
        qr/Invalid CODE attribute: Signal\('x'\)/,
        'attribute is rejected as an invalid CODE attribute',
    );
});

# Constraints 3 and 4 need modules loaded via require() at runtime — after
# the program's global CHECK pass — exactly how a worker loads user workflow
# modules. Fixture modules are written to a temp dir and required from there.
my $fixture_dir = File::Temp->newdir('attr-handlers-XXXXXX', TMPDIR => 1);
_write_fixture_modules("$fixture_dir");
unshift @INC, "$fixture_dir";

T2->subtest('constraint 3: ATTR(CODE,BEGIN) fires on runtime require; CHECK never does' => sub {
    no warnings 'once';    # the CHECK registry is (correctly) only read once
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    require AttrSpike::BaseBegin;
    require AttrSpike::WFBegin;
    require AttrSpike::BaseCheck;
    require AttrSpike::WFCheck;

    my $begin_entries = $AttrSpike::BaseBegin::REGISTRY{'AttrSpike::WFBegin'}{signals} // [];
    T2->is(scalar(@$begin_entries), 2, 'BEGIN-phase handler fired for both decorated methods');
    T2->is($_->{phase}, 'BEGIN', "entry registered during BEGIN phase") for @$begin_entries;

    my $check_entries = $AttrSpike::BaseCheck::REGISTRY{'AttrSpike::WFCheck'}{signals} // [];
    T2->is(scalar(@$check_entries), 0, 'CHECK-phase handler never fired after runtime require');
    T2->is(\@warnings, [], 'CHECK-phase handler is skipped silently, with no warnings');
});

T2->subtest('constraint 4: $data arrives as arrayref or undef, never a bare string' => sub {
    my $entries = $AttrSpike::BaseBegin::REGISTRY{'AttrSpike::WFBegin'}{signals} // [];
    my ($named) = grep { defined $_->{data} } @$entries;
    my ($bare)  = grep { !defined $_->{data} } @$entries;

    T2->ok($named, 'found the :Signal(lateSig) entry') or return;
    T2->is(ref($named->{data}), 'ARRAY', q{:Signal('lateSig') data is an arrayref});
    T2->is($named->{data}, ['lateSig'], 'arrayref holds the literal signal name');

    T2->ok($bare, 'found the bare :Signal entry') or return;
    T2->is($bare->{data}, undef, 'bare :Signal data is undef');

    # Registration contract (spec 10.1): a captured method ref is invocable
    # both as $ref->($instance, @args) and $instance->$ref(@args).
    my $instance = AttrSpike::WFBegin->new;
    my $ref = $named->{ref};
    T2->is($ref->($instance, 'V1'), 'named(V1) self=AttrSpike::WFBegin', 'arrow-call on captured ref works');
    T2->is($instance->$ref('V2'), 'named(V2) self=AttrSpike::WFBegin', 'method-call on captured ref works');
});

T2->done_testing;

# Writes the runtime-require fixture modules: a BEGIN-phase base and a
# CHECK-phase base, each with a subclass decorating methods with :Signal.
sub _write_fixture_modules ($dir) {
    make_path("$dir/AttrSpike");

    my %modules = (
        'AttrSpike/BaseBegin.pm' => <<~'PM',
            use v5.38;
            use feature 'class';
            no warnings 'experimental::class';
            class AttrSpike::BaseBegin {
                use Attribute::Handlers;
                our %REGISTRY;
                sub Signal :ATTR(CODE,BEGIN) {
                    my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
                    push @{$REGISTRY{$pkg}{signals}},
                        { data => $data, ref => $ref, phase => $phase };
                }
            }
            1;
            PM
        'AttrSpike/WFBegin.pm' => <<~'PM',
            use v5.38;
            use feature 'class';
            no warnings 'experimental::class';
            class AttrSpike::WFBegin :isa(AttrSpike::BaseBegin) {
                method named_sig :Signal('lateSig') ($x) {
                    return "named($x) self=" . ref($self);
                }
                method bare_sig :Signal ($x) {
                    return "bare($x)";
                }
            }
            1;
            PM
        'AttrSpike/BaseCheck.pm' => <<~'PM',
            use v5.38;
            use feature 'class';
            no warnings 'experimental::class';
            class AttrSpike::BaseCheck {
                use Attribute::Handlers;
                our %REGISTRY;
                sub Signal :ATTR(CODE,CHECK) {
                    my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
                    push @{$REGISTRY{$pkg}{signals}},
                        { data => $data, ref => $ref, phase => $phase };
                }
            }
            1;
            PM
        'AttrSpike/WFCheck.pm' => <<~'PM',
            use v5.38;
            use feature 'class';
            no warnings 'experimental::class';
            class AttrSpike::WFCheck :isa(AttrSpike::BaseCheck) {
                method named_sig :Signal('lateSig') ($x) { return "named($x)" }
            }
            1;
            PM
    );

    for my $path (sort keys %modules) {
        open my $fh, '>', "$dir/$path" or die "cannot write $dir/$path: $!";
        print {$fh} $modules{$path};
        close $fh or die "cannot close $dir/$path: $!";
    }
    return;
}
