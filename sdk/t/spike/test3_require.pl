#!/usr/bin/perl
# ABOUTME: Test 8 - critical timing: does Attribute::Handlers fire when class
# is loaded via require() at runtime (after CHECK phase has passed)?
use v5.38;
use lib '/tmp/sdk-perl-spike';

print "Before require, CHECK is over.\n";
require MyBase;
print "Base loaded.\n";
require MyWF;
print "WF loaded.\n";

print "\n--- REGISTRY after runtime require ---\n";
for my $pkg (sort keys %Temporalio::Workflow::Definition::REGISTRY) {
    for my $kind (sort keys %{$Temporalio::Workflow::Definition::REGISTRY{$pkg}}) {
        for my $entry (@{$Temporalio::Workflow::Definition::REGISTRY{$pkg}{$kind}}) {
            print "  $pkg $kind: name=$entry->[0] ref=$entry->[1]\n";
        }
    }
}
my $inst = My::WF->new;
my $sigs = $Temporalio::Workflow::Definition::REGISTRY{'My::WF'}{signals} // [];
print "  num signals registered: ", scalar(@$sigs), "\n";
for my $e (@$sigs) {
    print "  invoke '$e->[0]': ", $e->[1]->($inst, "RT"), "\n";
}
