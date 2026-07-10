# ABOUTME: Author test asserting every shipped .pm has syntactically valid POD
# ABOUTME: (podchecker-clean), per spec section 16.7 / plan P5.3.
use v5.38;
use warnings;
use utf8;

use Test::More;

BEGIN {
    unless ( eval { require Test::Pod; Test::Pod->VERSION('1.41'); 1 } ) {
        plan skip_all => 'Test::Pod 1.41+ required for POD syntax checks';
    }
}

Test::Pod->import;

all_pod_files_ok( all_pod_files('lib') );
