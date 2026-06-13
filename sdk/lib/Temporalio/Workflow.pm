# ABOUTME: Workflow-author entry point (spec section 10) — `use Temporalio::Workflow;`.
# ABOUTME: Loads the definition base so :isa(Temporalio::Workflow::Definition) resolves.
package Temporalio::Workflow;

use v5.38;
use warnings;

# A user workflow module says `use Temporalio::Workflow;` and then declares
# `class My::Workflow :isa(Temporalio::Workflow::Definition)`. Loading the base
# here means the author does not have to `use` it separately, and the
# :Run/:Signal/:Query/:Update/:Init attribute handlers are in scope.
use Temporalio::Workflow::Definition ();

# The Temporalio::Workflow:: functional surface (execute_activity, start_timer,
# sleep, now, info, etc. — spec section 10.2) is added in later phases (the
# deterministic runner). This module is the loader for the definition surface.

1;

__END__

=head1 NAME

Temporalio::Workflow - entry point for workflow authors

=head1 SYNOPSIS

    use feature 'class';
    use Future::AsyncAwait;
    use Temporalio::Workflow;

    class My::Workflow::Greeting :isa(Temporalio::Workflow::Definition) {
        async method run :Run ($name) {
            return "Hello, $name!";
        }
    }

=head1 DESCRIPTION

C<use Temporalio::Workflow;> in a workflow module loads
L<Temporalio::Workflow::Definition> so the C<:isa> base resolves and the
C<:Run>/C<:Signal>/C<:Query>/C<:Update>/C<:Init> attribute handlers are in
scope. The workflow-context functional surface (C<Temporalio::Workflow::now>,
C<execute_activity>, etc. — spec section 10.2) is added in a later phase.

=cut
