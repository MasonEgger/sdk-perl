# ABOUTME: hello-world example — the SayHello activity. A class-based activity
# ABOUTME: definition (spec section 9.1): one :Defn method per activity.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Activity::Definition;

# A single activity, SayHello, that builds a greeting. Activities are where side
# effects live (network calls, database writes, ...). This one is pure for the
# example, but it runs in the worker's activity slot just like any other.
class HelloWorld::Activities :isa(Temporalio::Activity::Definition) {
    async method say_hello :Defn('SayHello') ($name) {
        return "Hello, $name!";
    }
}

1;
