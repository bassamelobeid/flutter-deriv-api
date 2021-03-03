use strict;
use warnings;

use Test::More;
use Test::Deep;

use BOM::Rules::Registry::Rule;

my %args = (
    name        => 'test_rule',
    description => 'A rule for testing',
    code        => sub { return 'test result' });

subtest 'Rule object instantiation' => sub {
    my $rule = BOM::Rules::Registry::Rule->new(%args);

    my @properties = qw/name description category error_code error_message/;

    is_deeply $rule, \%args, "New object's properties are correct";
    is $rule->apply, 'test result', 'Code is correctly called';
};

done_testing();
