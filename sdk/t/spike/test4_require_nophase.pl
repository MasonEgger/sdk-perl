#!/usr/bin/perl
# ABOUTME: Test 8 variant - :ATTR(CODE) with no explicit phase
use v5.38;
use lib '/tmp/sdk-perl-spike';

print "Before require\n";
require MyBase2;
require MyWF2;
print "After require\n";

my $sigs = $Temporalio::Workflow::Definition2::REGISTRY{'My::WF2'}{signals} // [];
print "num signals: ", scalar(@$sigs), "\n";
for my $e (@$sigs) {
    my $inst = My::WF2->new;
    print "  '$e->[0]' => ", $e->[1]->($inst, "X"), "\n";
}
