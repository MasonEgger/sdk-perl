# ABOUTME: Author test asserting 100% POD coverage on the public Temporalio::*
# ABOUTME: API surface, per spec section 16.7 / plan P5.3.
use v5.38;
use warnings;
use utf8;

use Test::More;

BEGIN {
    unless ( eval { require Test::Pod::Coverage; Test::Pod::Coverage->VERSION('1.08'); 1 } ) {
        plan skip_all => 'Test::Pod::Coverage 1.08+ required for POD coverage checks';
    }
    unless ( eval { require Pod::Coverage; 1 } ) {
        plan skip_all => 'Pod::Coverage required for POD coverage checks';
    }
}

Test::Pod::Coverage->import;

# Conventions for what counts as "private" across the whole SDK:
#   - leading-underscore subs/methods are private helpers
#   - new/import/unimport are infrastructure, not documented per-class
#   - attribute handlers (:ATTR(CODE,BEGIN)) compile to subs but are an
#     internal mechanism (spec section 10.1)
#   - FFI trampolines / callback entry points are internal
# Per-class trustme additions live in the %TRUSTME table below.
my $also_private = [
    qr/^_/,                      # private helpers
    qr/^(?:BUILD|ADJUST|DESTROY)$/,
    qr/^new$/,                   # constructor is infrastructure (see above)
    qr/^import$/,
    qr/^unimport$/,
];

# Subs that look public (no leading underscore) but are an internal or
# collectively-documented mechanism, keyed by package. These are covered by
# prose in their module POD (a "=head1 FUNCTIONS"/"Logging level methods"
# section) rather than a per-sub "=head2", so they are trusted here:
#
#   - Temporalio::Core::FFI: the raw C ABI bindings (names drop the
#     temporal_core_ / temporalio_perl_bridge_ prefixes). Internal; wrapped by
#     the Runtime/Client/Worker classes. Contract is the pinned C header.
#   - Temporalio::Workflow::Logger: the Log::Any level surface (info/warn/...,
#     the *f variants, and the is_* predicates) generated in a loop and
#     documented collectively per spec section 10.4.
my %TRUSTME = (
    'Temporalio::Core::FFI' => [ qr/^[a-z]/ ],
    'Temporalio::Workflow::Logger' => [
        qr/^(?:is_)?(?:trace|debug|info|notice|warning|warn|error|err|critical|crit|fatal|alert|emergency)f?$/,
    ],
    # The client outbound chain root (spec section 27.2): an internal mechanism
    # whose methods mirror the OutboundInterceptor surface and perform the real
    # RPC. Documented collectively in Temporalio::Client::Interceptor's POD.
    'Temporalio::Client::_RootOutbound' => [ qr/^[a-z]/ ],
    # The worker inbound chain roots (spec section 27.2): internal mechanisms
    # whose methods mirror the ActivityInbound / WorkflowInbound surface and
    # perform the real activity/workflow dispatch via the input's _root coderef.
    # Documented collectively in Temporalio::Worker::Interceptor's POD.
    'Temporalio::Worker::_RootActivityInbound' => [ qr/^[a-z]/ ],
    'Temporalio::Worker::_RootWorkflowInbound' => [ qr/^[a-z]/ ],
);

my @modules = all_modules('lib');

plan tests => scalar @modules;

for my $module ( sort @modules ) {
    my $trustme = $TRUSTME{$module} // [];
    pod_coverage_ok(
        $module,
        {
            also_private => $also_private,
            trustme      => $trustme,
            coverage_class => 'Pod::Coverage::CountParents',
        },
        "$module has full POD coverage",
    );
}
