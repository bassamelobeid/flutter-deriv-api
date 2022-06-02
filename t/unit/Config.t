use strict;
use warnings;
use Test::More;

use Scalar::Util qw(refaddr);
use BOM::Config;

subtest 'Test YAML return correct structure' => sub {
    my $config = BOM::Config::node();
    ok(exists $config->{node},                     'Correctly returns node information');
    ok(exists $config->{node}->{environment},      'Has information about environment');
    ok(exists $config->{node}->{operation_domain}, 'Has information about operation_domain');
    ok(exists $config->{node}->{roles},            'Has information about roles');
    is(ref $config->{node}->{roles}, 'ARRAY', 'Has information about roles');

    # these tests for all configs in BOM::Config.pm
};

subtest 'Config stores state' => sub {
    is(refaddr BOM::Config::node(), refaddr BOM::Config::node(), 'Returns the same object');

    # these tests for all configs in BOM::Config.pm
};

done_testing;
