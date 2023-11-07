use strict;
use warnings;
use Test::More;

# Load the module to be tested
use BOM::RPC::v3::Annotations qw(annotate_db_calls);

# Test Case 1: Test with read and write specified
my %annotation1 = annotate_db_calls(
    read     => ['clientdb', 'authdb'],
    write    => ['userdb',   'clientdb'],
    readonly => 0
);

is_deeply(
    \%annotation1,
    {
        database => {
            read     => ['clientdb', 'authdb'],
            write    => ['userdb',   'clientdb'],
            readonly => 0
        }
    },
    'Test Case 1: read and write specified'
);

# Test Case 2: Test with read only
my %annotation2 = annotate_db_calls(
    read     => ['clientdb', 'authdb'],
    readonly => 1
);

is_deeply(
    \%annotation2,
    {
        database => {
            read     => ['clientdb', 'authdb'],
            write    => [],
            readonly => 1
        }
    },
    'Test Case 2: read only'
);

# Test Case 3: Test with write only
my %annotation3 = annotate_db_calls(
    read     => undef,
    write    => ['userdb', 'clientdb'],
    readonly => 0
);

is_deeply(
    \%annotation3,
    {
        database => {
            read     => [],
            write    => ['userdb', 'clientdb'],
            readonly => 0
        }
    },
    'Test Case 3: write only'
);

done_testing();
