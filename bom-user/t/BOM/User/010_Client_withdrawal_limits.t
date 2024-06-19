#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More qw( no_plan );
use Test::MockTime;
use Test::Exception;
use Math::Round                                qw( round );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::User::Client;

# create client object
my $client;
lives_ok { $client = BOM::User::Client->new({loginid => 'CR0026'}) } 'Can create client object.';
my $withdrawal_limits = $client->get_withdrawal_limits();

is($withdrawal_limits->{'frozen_free_gift'},         0,   'USD frozen_free_gift is 0');
is($withdrawal_limits->{'free_gift_turnover_limit'}, 500, 'USD free_gift_turnover_limit is 500');

subtest 'CR0027.' => sub {
    plan tests => 2;

    my $client            = BOM::User::Client->new({loginid => 'CR0027'});
    my $withdrawal_limits = $client->get_withdrawal_limits();

    is($withdrawal_limits->{'frozen_free_gift'},         0,   'USD frozen_free_gift is 0');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 250, 'USD free_gift_turnover_limit is 250');
};

subtest 'CR0028.' => sub {
    plan tests => 2;

    my $client            = BOM::User::Client->new({loginid => 'CR0028'});
    my $withdrawal_limits = $client->get_withdrawal_limits();

    cmp_ok($withdrawal_limits->{'frozen_free_gift'}, '==', 20, 'USD frozen_free_gift is 20');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 500, 'USD free_gift_turnover_limit is 500');
};

done_testing();
