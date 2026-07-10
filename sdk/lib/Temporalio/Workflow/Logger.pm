# ABOUTME: Replay-aware workflow logger (spec section 10.4 / T-wf-9). Wraps a
# ABOUTME: Log::Any logger; discards output while the runner is replaying.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Log::Any ();

# A logger handed to workflow code by Temporalio::Workflow::logger. It mirrors
# the Log::Any logging API (info/warn/error/debug/trace/notice/critical/...) but
# routes a call to the underlying Log::Any logger ONLY when the owning runner is
# NOT replaying — so a line logged while re-applying history is not duplicated
# (spec section 10.4 / T-wf-9; MUST-match sdk-python LoggerAdapter.isEnabledFor,
# which returns false during replay-history events). The is_* level predicates
# always return true so user code can build messages regardless of replay state
# (spec section 10.4). Workflow context (run_id, workflow_type) rides along on
# every record's structured data so downstream handlers can attribute the line.
class Temporalio::Workflow::Logger {
    # The active runner, consulted for is_replaying on every log call. Held
    # weakly is unnecessary here (the runner owns the logger for the run's
    # lifetime), so a plain reference is fine.
    field $runner :param;

    # The underlying Log::Any logger that actually emits records. Defaults to a
    # logger in the Temporalio::Workflow category so users can filter by
    # subsystem via Log::Any::Adapter's category filter (spec section 16.4).
    field $logger :param = undef;

    # Structured context attached to every record (spec section 10.4): the
    # workflow run id and type, derived from the runner's info.
    field %context;

    ADJUST {
        $logger //= Log::Any->get_logger(category => 'Temporalio::Workflow');
        my $info = $runner->info;
        %context = (
            workflow_run_id => $info->{run_id},
            workflow_type   => $info->{workflow_type},
        );
    }

    # The underlying Log::Any logger (for tests / advanced configuration).
    method base_logger { return $logger }

    # The workflow context attached to every record.
    method context { return { %context } }

    # The standard Log::Any level methods. Each forwards to the underlying
    # logger only when the runner is NOT replaying; during replay the call is a
    # no-op so the line is not duplicated as history is re-applied.
    for my $level (qw(
        trace debug info notice warning warn error err
        critical crit fatal alert emergency
    )) {
        no strict 'refs';
        *{"Temporalio::Workflow::Logger::$level"} = sub ($self, @args) {
            return if $self->_replaying;
            return $self->base_logger->$level(@args);
        };
        # Formatting variants (infof/debugf/...) mirror Log::Any.
        my $fmt = "${level}f";
        *{"Temporalio::Workflow::Logger::$fmt"} = sub ($self, @args) {
            return if $self->_replaying;
            return $self->base_logger->$fmt(@args);
        };
        # The is_* predicates always return true so user code can build the
        # message regardless of replay state (spec section 10.4).
        *{"Temporalio::Workflow::Logger::is_$level"} = sub { return 1 };
    }

    method _replaying { return $runner->is_replaying ? 1 : 0 }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::Logger - replay-aware logger for workflow code

=head1 SYNOPSIS

    my $log = Temporalio::Workflow::logger();
    $log->info("processing order $id");   # suppressed during replay

=head1 DESCRIPTION

The logger returned by C<Temporalio::Workflow::logger> (spec section 10.4). It
wraps a L<Log::Any> logger and forwards each level call (C<info>, C<warn>,
C<error>, ...) to it B<only when the owning runner is not replaying>, so a line
logged while re-applying history is not emitted twice (spec test T-wf-9). The
C<is_*> level predicates always return true so user code can build messages
regardless of replay state.

The logger carries the workflow run id and type as structured context (via
C<context>) so downstream handlers can attribute each line to its workflow.

=head1 CONSTRUCTOR

=head2 new

    my $log = Temporalio::Workflow::Logger->new(runner => $runner, logger => $log_any);

Constructs the logger. C<runner> (required) is the owning
L<Temporalio::Workflow::Runner>, consulted for replay state on every call.
C<logger> (optional) is the underlying L<Log::Any> logger; it defaults to a
logger in the C<Temporalio::Workflow> category.

=head1 METHODS

=head2 base_logger

The underlying L<Log::Any> logger (for tests or advanced configuration).

=head2 context

Returns a hashref of the workflow context (C<workflow_run_id>,
C<workflow_type>) attached to every record.

=head2 Logging level methods

This logger mirrors the L<Log::Any> level API. The level emitters

    trace debug info notice warning warn error err
    critical crit fatal alert emergency

and their C<sprintf>-style C<*f> variants (C<infof>, C<debugf>, ...) each
forward to the underlying logger B<only when the runner is not replaying>, so a
line logged while re-applying history is not emitted twice (spec section 10.4 /
test T-wf-9). The matching C<is_*> predicates (C<is_info>, C<is_debug>, ...)
always return true so workflow code can build messages regardless of replay
state.

=cut
