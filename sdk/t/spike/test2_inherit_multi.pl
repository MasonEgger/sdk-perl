#!/usr/bin/perl
# ABOUTME: Test 5+6+7 - multiple attrs, inheritance, calling captured referent
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Workflow::Definition {
    use Attribute::Handlers;
    our %REGISTRY;
    sub Signal :ATTR(CODE,CHECK) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        my $name = ref($data) eq 'ARRAY' ? $data->[0] : ($data // '_default');
        print STDERR "Signal: pkg=$pkg name=$name ref=$ref\n";
        push @{$REGISTRY{$pkg}{signals}}, [$name, $ref];
    }
    sub Query :ATTR(CODE,CHECK) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        my $name = ref($data) eq 'ARRAY' ? $data->[0] : ($data // '_default');
        print STDERR "Query:  pkg=$pkg name=$name ref=$ref\n";
        push @{$REGISTRY{$pkg}{queries}}, [$name, $ref];
    }
}

class Base::WF :isa(Temporalio::Workflow::Definition) {
    method base_signal :Signal('baseSig') ($x) { return "base_signal($x)" }
}

class Child::WF :isa(Base::WF) {
    method child_signal :Signal('childSig') ($x) { return "child_signal($x)" }
    method combo :Signal('a') :Query('b') ($x) { return "combo($x) self=" . ref($self) }
}

print "\n--- REGISTRY DUMP ---\n";
use Data::Dumper; $Data::Dumper::Sortkeys = 1;
for my $pkg (sort keys %Temporalio::Workflow::Definition::REGISTRY) {
    print "PKG: $pkg\n";
    for my $kind (sort keys %{$Temporalio::Workflow::Definition::REGISTRY{$pkg}}) {
        for my $entry (@{$Temporalio::Workflow::Definition::REGISTRY{$pkg}{$kind}}) {
            print "  $kind: name=$entry->[0] ref=$entry->[1]\n";
        }
    }
}

print "\n--- INVOKE captured refs ---\n";
my $child = Child::WF->new;
for my $entry (@{$Temporalio::Workflow::Definition::REGISTRY{'Child::WF'}{signals} // []}) {
    my ($n, $r) = @$entry;
    print "  invoke child sig '$n': ", $r->($child, "VAL"), "\n";
}
# can a Child::WF instance call a Base::WF-registered ref?
my $base_entry = $Temporalio::Workflow::Definition::REGISTRY{'Base::WF'}{signals}[0];
if ($base_entry) {
    print "  invoke base sig '$base_entry->[0]' on child instance: ",
        $base_entry->[1]->($child, "INH"), "\n";
}
