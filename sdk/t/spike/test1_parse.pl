#!/usr/bin/perl
# ABOUTME: Test 1 - does :Signal attribute parse on a method in feature 'class'?
# Defines :Signal via Attribute::Handlers, then decorates a method.
use v5.38;
use feature 'class';
no warnings 'experimental::class';

package My::Attrs {
    use Attribute::Handlers;
    sub Signal :ATTR(CODE,CHECK) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        print STDERR "HANDLER FIRED: pkg=$pkg attr=$attr phase=$phase data=", (defined $data ? "[$data]" : "(undef)"), "\n";
    }
}

class My::WF {
    BEGIN { My::Attrs->import; }
    method on_change :Signal('changeGreeting') ($new) {
        return "got $new";
    }
}

print "PARSED OK\n";
my $wf = My::WF->new;
print "RESULT: ", $wf->on_change("hello"), "\n";
