# ABOUTME: Base class loaded via require to test runtime handler firing
# Defines :Signal attribute via Attribute::Handlers.
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Workflow::Definition {
    use Attribute::Handlers;
    our %REGISTRY;
    sub Signal :ATTR(CODE,CHECK) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        my $name = ref($data) eq 'ARRAY' ? $data->[0] : ($data // '_default');
        print STDERR "[CHECK] Signal fired: pkg=$pkg name=$name phase=$phase\n";
        push @{$REGISTRY{$pkg}{signals}}, [$name, $ref];
    }
}
1;
