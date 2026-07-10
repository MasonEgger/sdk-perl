# ABOUTME: Base variant using :ATTR(CODE) without explicit phase
# Tests whether default-phase handler fires after runtime require.
use v5.38;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Workflow::Definition2 {
    use Attribute::Handlers;
    our %REGISTRY;
    # No explicit phase - default tries BEGIN/CHECK/INIT/END all
    sub Signal :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        my $name = ref($data) eq 'ARRAY' ? $data->[0] : ($data // '_default');
        print STDERR "[$phase] Signal fired: pkg=$pkg name=$name\n";
        push @{$REGISTRY{$pkg}{signals}}, [$name, $ref];
    }
}
1;
