# ABOUTME: Load test for the Temporalio::SDK distribution entry point.
# ABOUTME: Asserts the module compiles and declares the expected version.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

my $loaded = eval { require Temporalio::SDK; 1 };
T2->ok($loaded, 'Temporalio::SDK loads') or T2->diag($@);
T2->is($Temporalio::SDK::VERSION, '0.2.0', 'Temporalio::SDK::VERSION is 0.2.0');

T2->done_testing;
