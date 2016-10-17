#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Test::MockTime;
use Test::More qw( no_plan );
use Test::Exception;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use BOM::Platform::Client;
use Date::Utility;
use BOM::Platform::Client::Utility;
use BOM::Test::Data::Utility::Product;

initialize_realtime_ticks_db();

my $now = Date::Utility->new;

subtest 'CR0027.' => sub {
    plan tests => 2;

    my $client = BOM::Platform::Client->new({loginid => 'CR0027'});
    my $withdrawal_limits = $client->get_withdrawal_limits();

    is($withdrawal_limits->{'frozen_free_gift'},         0,   'USD frozen_free_gift is 0');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 250, 'USD free_gift_turnover_limit is 250');
};

subtest 'CR0028.' => sub {
    plan tests => 2;

    my $client = BOM::Platform::Client->new({loginid => 'CR0028'});
    my $withdrawal_limits = $client->get_withdrawal_limits();

    cmp_ok($withdrawal_limits->{'frozen_free_gift'}, '==', 20, 'USD frozen_free_gift is 20');
    is($withdrawal_limits->{'free_gift_turnover_limit'}, 500, 'USD free_gift_turnover_limit is 500');
};

Test::MockTime::restore_time();
