#!/usr/bin/perl
# ABOUTME: Test 1c - base class is a 'class', uses Attribute::Handlers inside
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Workflow::Definition {
    use Attribute::Handlers;
    our %REGISTRY;
    sub Signal :ATTR(CODE,CHECK) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        print STDERR "Signal HANDLER FIRED: pkg=$pkg attr=$attr phase=$phase data=", (defined $data ? "[$data]" : "(undef)"), " ref=$ref sym=$sym\n";
        $REGISTRY{$pkg}{$data // '_default'} = $ref;
    }
    sub Query :ATTR(CODE,CHECK) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        print STDERR "Query HANDLER FIRED: pkg=$pkg attr=$attr phase=$phase data=", (defined $data ? "[$data]" : "(undef)"), "\n";
        $REGISTRY{$pkg}{$data // 'q_default'} = $ref;
    }
}

class My::WF :isa(Temporalio::Workflow::Definition) {
    method on_change :Signal('changeGreeting') ($new) {
        return "got $new from " . ref($self);
    }
    method status :Query ($) {
        return "ok";
    }
}

print "PARSED OK\n";
my $wf = My::WF->new;
print "calling on_change directly: ", $wf->on_change("hi"), "\n";

print "\n--- REGISTRY ---\n";
for my $pkg (keys %Temporalio::Workflow::Definition::REGISTRY) {
    for my $name (keys %{$Temporalio::Workflow::Definition::REGISTRY{$pkg}}) {
        my $ref = $Temporalio::Workflow::Definition::REGISTRY{$pkg}{$name};
        print "  $pkg / $name => $ref\n";
        my $inst = $pkg->new;
        my $r1 = eval { $ref->($inst, "via-arrow") };
        print "    arrow-call: ", (defined $r1 ? $r1 : "ERR: $@"), "\n";
        my $r2 = eval { $inst->$ref("via-method") };
        print "    method-call: ", (defined $r2 ? $r2 : "ERR: $@"), "\n";
    }
}
