# ABOUTME: Pure-Perl emission backend test double for the user-facing metric
# ABOUTME: meter (spec R83): records create_instrument/attributes/record calls.
use v5.38;
use warnings;

# Duck-typed stand-in for Temporalio::Runtime::MetricMeter::CoreBackend: the
# meter/instrument wrapper drives this exactly like the FFI-backed backend, so
# unit and replay tests can assert emissions without a core runtime.
#
# Backend contract (shared with CoreBackend):
#   create_instrument($kind, $name, $description, $unit) -> opaque handle
#   attributes($base_or_undef, \%attrs)                  -> opaque handle
#   record($instrument_handle, $value, $attrs_or_undef)  -> void
package MetricBuffer;

sub new ($class) {
    return bless { instruments => [], records => [] }, $class;
}

# Every instrument ever created: [{ kind, name, description, unit }, ...].
sub instruments ($self) { return $self->{instruments} }

# Every recorded value: [{ name, kind, value, attrs }, ...].
sub records ($self) { return $self->{records} }

sub create_instrument ($self, $kind, $name, $description, $unit) {
    my $handle = {
        kind        => $kind,
        name        => $name,
        description => $description,
        unit        => $unit,
    };
    push @{ $self->{instruments} }, $handle;
    return $handle;
}

# Append semantics: the returned set is the base set plus the new pairs.
sub attributes ($self, $base, $attrs) {
    return { %{ $base // {} }, %{ $attrs // {} } };
}

sub record ($self, $handle, $value, $attrs) {
    push @{ $self->{records} }, {
        name  => $handle->{name},
        kind  => $handle->{kind},
        value => $value,
        attrs => { %{ $attrs // {} } },
    };
    return;
}

1;
