# ABOUTME: Generates the per-RPC methods of the raw service handles (spec R91)
# ABOUTME: from the vendored proto service descriptors, one snake_case method
# ABOUTME: per rpc, each delegating to the handle's generic call().
package Temporalio::Client::RawService;

use v5.38;
use warnings;

use Temporalio::Core::Proto ();
use Temporalio::Exception::Runtime ();

# Per-target-package one-shot guard: the methods land in the shared symbol
# table, so a second handle construction is a no-op.
my %INSTALLED;

# install_rpc_methods($target_package, $service_full_name)
#
# Reads the named service's descriptor from the loaded proto schema and
# installs one method per rpc into $target_package: the Perl method name is
# the snake_case form of the rpc name (Python parity: sdk-python's generated
# bridge/services_generated.py exposes count_workflow_executions and friends),
# and each method is a thin wrapper
#
#     $handle->add_search_attributes($request, %opts)
#       == $handle->call('AddSearchAttributes', $request,
#                        response_class => <resolved from the descriptor>,
#                        %opts)
#
# so the CamelCase rpc name the c-bridge dispatches on (client.rs
# call_*_service match arms) and the response class both come from the proto
# service descriptor rather than a hand-listed map (parity audit client
# finding 1). Idempotent per target package.
sub install_rpc_methods ($target, $service_full_name) {
    return if $INSTALLED{$target};

    my $service = Temporalio::Core::Proto::schema()->service($service_full_name)
        or Temporalio::Exception::Runtime->throw(
            message => "no proto service descriptor for '$service_full_name';"
                     . ' is its .proto a Temporalio::Core::Proto root?');
    # The service's proto package, for qualifying bare method type names.
    (my $package = $service_full_name) =~ s/\.[^.]+\z//;

    for my $rpc (@{ $service->methods }) {
        my $name           = $rpc->{name};
        my $response_class = Temporalio::Core::Proto::resolve(
            _qualified($rpc->{output_type}, $package));
        my $method         = _snake_case($name);
        no strict 'refs';
        *{"${target}::${method}"} = sub {
            my ($self, $request, %opts) = @_;
            return $self->call(
                $name, $request, response_class => $response_class, %opts);
        };
    }

    $INSTALLED{$target} = 1;
    return;
}

# A descriptor method type as written in the .proto source: a leading dot
# marks it fully qualified; a bare name lives in the service's own package
# (the only two spellings in the vendored service files); anything already
# dotted passes through.
sub _qualified ($type, $package) {
    return $1 if $type =~ /\A\.(.+)\z/s;
    return $type =~ /\./ ? $type : "$package.$type";
}

# CamelCase rpc name -> snake_case method name, the same convention protoc's
# Python generators use (GetSystemInfo -> get_system_info).
sub _snake_case ($name) {
    $name =~ s/([A-Z]+)([A-Z][a-z])/${1}_${2}/g;
    $name =~ s/([a-z0-9])([A-Z])/${1}_${2}/g;
    return lc $name;
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::RawService - generate raw service handle methods from proto descriptors

=head1 SYNOPSIS

    use Temporalio::Client::RawService ();

    Temporalio::Client::RawService::install_rpc_methods(
        'Temporalio::Client::OperatorService',
        'temporal.api.operatorservice.v1.OperatorService');

=head1 DESCRIPTION

The method-generation backend of the raw service handles (spec R91;
Python parity C<_client.py:307-322> over the generated
C<bridge/services_generated.py> service classes). C<install_rpc_methods>
reads a service descriptor from the L<Temporalio::Core::Proto> schema and
installs one snake_case method per rpc into the target handle package; each
generated method delegates to the handle's generic C<call> with the
CamelCase rpc name (the form the c-bridge dispatches on) and the response
class resolved from the descriptor's output type. Generating from the
descriptors, rather than hand-listing the 100+ workflow-service RPCs, keeps
the surface in lockstep with the vendored protos (parity audit client
finding 1).

=head1 FUNCTIONS

=head2 install_rpc_methods($target_package, $service_full_name)

Installs the named proto service's rpc surface into C<$target_package> as
snake_case methods, each calling C<< $target_package->call >> with the rpc's
CamelCase name and descriptor-resolved response class. Idempotent per target
package; throws L<Temporalio::Exception::Runtime> when the schema has no such
service. Internal: the handles install their own methods at construction.

=cut
