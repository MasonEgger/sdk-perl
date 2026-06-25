# ABOUTME: Best-effort workflow determinism guard (spec §29.4): process-global
# ABOUTME: CORE::GLOBAL:: overrides of the time/entropy builtins + Time::HiRes
# ABOUTME: symbol-table overrides, gated on $Runner::CURRENT, escapable via the
# ABOUTME: dynamically-scoped Unsafe::illegal_call_tracing_disabled hatch.
package Temporalio::Workflow::DeterminismGuard;

use v5.38;
use warnings;

# The CORE::GLOBAL:: overrides need classic PROTOTYPES (so an unqualified `time`
# with no parens still parses as a nullary builtin call, `rand` stays unary,
# etc.). Under `use v5.38` the `(...)` after `sub` is a signature, not a
# prototype, so disable signatures in this file and declare prototypes the old
# way. Everything else here is plain subs.
no feature 'signatures';

use Temporalio::Exception::Nondeterminism ();

# Dynamically-scoped suppression depth. While > 0 the guard delegates to the
# real builtin even inside workflow context. Raised (via Syntax::Keyword::
# Dynamically) by Temporalio::Workflow::Unsafe::illegal_call_tracing_disabled so
# the suppression unwinds correctly across an await (Future::AsyncAwait panics on
# `local` - spec §16.1). Lives in this package so the overrides read one symbol.
our $SUPPRESS_DEPTH = 0;

# Set once install() has wired the overrides; install() is idempotent so a second
# call is a no-op (re-installing CORE::GLOBAL:: overrides would not double-wrap,
# but tracking the flag keeps is_installed honest and skips redundant work).
my $INSTALLED = 0;

# True when (and only when) a workflow body is on the stack (the runner sets
# $Temporalio::Workflow::Runner::CURRENT via `dynamically` for the duration of
# process_activation) AND tracing is not suppressed. This is the single gate the
# overrides consult; "in context" is exactly `defined $Runner::CURRENT` per spec.
sub _guarding {
    return defined $Temporalio::Workflow::Runner::CURRENT
        && $SUPPRESS_DEPTH == 0;
}

# Throw a Nondeterminism naming the trapped builtin. The runner routes a
# Nondeterminism escaping the body the same as a recorded one: a workflow-TASK
# failure by default, a workflow failure when nondeterminism_as_workflow_fail.
sub _trap {
    my ($name) = @_;
    Temporalio::Exception::Nondeterminism->throw(
        message => "non-determinism: workflow code called the '$name' builtin, "
            . "which reads wall-clock time or OS entropy. Use the deterministic "
            . "Temporalio::Workflow primitives (now/time/random/sleep), or wrap "
            . "the call in Temporalio::Workflow::Unsafe::illegal_call_tracing_disabled "
            . "if it is provably safe.",
    );
}

# install() - wire the overrides. Idempotent. The override set is NARROWED (spec
# §29.4 M2) to the time/entropy surface only: time/localtime/gmtime/rand/srand/
# sleep as CORE::GLOBAL:: overrides, plus Time::HiRes::{time,gettimeofday,sleep}
# as symbol-table overrides. The IO/process builtins (open/fork/kill/system/
# exec/readpipe) are deliberately NOT overridden - a process-global override of
# those risks trapping IO::Async loop internals and the sync-activity fork pool
# (which run on the same main thread where $Runner::CURRENT is set), for little
# gain (such ops already break replay with no matching command).
sub install {
    return if $INSTALLED;

    no warnings 'redefine';

    # CORE::GLOBAL:: overrides intercept only UNqualified calls compiled after
    # the override exists; explicit CORE:: calls bind to the builtin directly
    # and are NOT trapped (a documented best-effort gap - T-det-7).
    *CORE::GLOBAL::time = sub () {
        _trap('time') if _guarding();
        return CORE::time();
    };

    *CORE::GLOBAL::rand = sub (;$) {
        _trap('rand') if _guarding();
        return @_ ? CORE::rand($_[0]) : CORE::rand();
    };

    *CORE::GLOBAL::srand = sub (;$) {
        _trap('srand') if _guarding();
        return @_ ? CORE::srand($_[0]) : CORE::srand();
    };

    *CORE::GLOBAL::sleep = sub (;$) {
        _trap('sleep') if _guarding();
        return @_ ? CORE::sleep($_[0]) : CORE::sleep();
    };

    # localtime/gmtime are list-context sensitive: in list context they return
    # the 9-element struct, in scalar context the formatted string. Forward the
    # caller's context with wantarray.
    *CORE::GLOBAL::localtime = sub (;$) {
        _trap('localtime') if _guarding();
        my $t = @_ ? $_[0] : CORE::time();
        return wantarray ? CORE::localtime($t) : scalar CORE::localtime($t);
    };

    *CORE::GLOBAL::gmtime = sub (;$) {
        _trap('gmtime') if _guarding();
        my $t = @_ ? $_[0] : CORE::time();
        return wantarray ? CORE::gmtime($t) : scalar CORE::gmtime($t);
    };

    # Time::HiRes exports/installs sub-style functions, so a CORE::GLOBAL::
    # override does not reach them; override the package symbols directly. Only
    # the wall-clock readers (time, gettimeofday) and the sleeper are trapped;
    # the duration helpers (tv_interval) are pure arithmetic and left alone.
    require Time::HiRes;
    my $hires_time         = \&Time::HiRes::time;
    my $hires_gettimeofday = \&Time::HiRes::gettimeofday;
    my $hires_sleep        = \&Time::HiRes::sleep;
    # Declare the overrides with the SAME prototypes Time::HiRes ships (time and
    # gettimeofday are nullary `()`, sleep is `(;@)`), so redefining the symbols
    # does not warn "Prototype mismatch" and call sites keep their parse.
    *Time::HiRes::time = sub () {
        _trap('Time::HiRes::time') if _guarding();
        return $hires_time->();
    };
    *Time::HiRes::gettimeofday = sub () {
        _trap('Time::HiRes::gettimeofday') if _guarding();
        return $hires_gettimeofday->();
    };
    *Time::HiRes::sleep = sub (;@) {
        _trap('Time::HiRes::sleep') if _guarding();
        return $hires_sleep->(@_);
    };

    $INSTALLED = 1;
    return;
}

# is_installed() - reports whether install() has wired the overrides. The guard
# cannot be cleanly uninstalled (the overrides are process-global), so a worker
# that disables the guard simply never installs it; this predicate exists for
# the test and for diagnostics.
sub is_installed { return $INSTALLED ? 1 : 0 }

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::DeterminismGuard - best-effort workflow determinism guard

=head1 DESCRIPTION

Installs process-global overrides for the time/entropy builtins so that calling
them from inside a workflow body throws L<Temporalio::Exception::Nondeterminism>
rather than reading wall-clock time or OS entropy (spec §29.4). The guard is
B<best-effort>: Perl has neither Python's import sandbox nor Ruby's TracePoint,
so this follows Ruby's I<model> (trap globally, act only in workflow context,
escape via Unsafe) with a coarser I<mechanism>.

=head2 What is trapped

The override set is narrowed (spec §29.4, decision M2) to the time/entropy
surface only:

=over

=item *

C<CORE::GLOBAL::> overrides of C<time>, C<localtime>, C<gmtime>, C<rand>,
C<srand>, C<sleep>.

=item *

Symbol-table overrides of C<Time::HiRes::time>, C<Time::HiRes::gettimeofday>,
C<Time::HiRes::sleep>.

=back

The IO/process builtins (C<open>, C<fork>, C<kill>, C<system>, C<exec>,
C<readpipe>) are B<not> overridden: a process-global override of those would
risk trapping the IO::Async loop and the sync-activity fork pool (which run on
the same main thread where C<$Runner::CURRENT> is set), for little gain.

=head2 Documented gaps

The guard cannot trap C<CORE::>-qualified calls (e.g. C<CORE::time>),
pre-compiled call sites (overrides only affect call sites compiled after
install), or raw socket builtins. The deterministic replacement surface
(L<Temporalio::Workflow/now>, C<time>, C<random>, C<sleep>) remains the primary
correctness mechanism; this guard is a secondary net.

=head1 FUNCTIONS

=head2 install

C<< Temporalio::Workflow::DeterminismGuard::install() >> wires the overrides.
Idempotent: a second call is a no-op. Default ON (the worker installs it unless
C<disable_determinism_guard> is set). Installing the guard is safe outside
workflow context: each override delegates straight to the real builtin unless a
workflow body is on the stack (C<defined $Runner::CURRENT>) and tracing is not
suppressed.

=head2 is_installed

Returns true once L</install> has run. The guard cannot be cleanly uninstalled,
so a worker that disables the guard simply never installs it.

=head1 SEE ALSO

L<Temporalio::Workflow::Unsafe/illegal_call_tracing_disabled> - the
dynamically-scoped escape hatch that suppresses the guard for a block.

=cut
