use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Deep;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Affiliate;

subtest 'set and get' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CRA',
        email       => 'affiliate@deriv.com',
    });

    my $affiliate = $client->get_client_instance($client->loginid);
    my $result;

    lives_ok {
        $result = $affiliate->set_affiliate_info({affiliate_plan => 'turnover'});
    }
    'Can set affiliate plan turnover';

    cmp_deeply $result,
        {
        affiliate_loginid => $client->loginid,
        affiliate_plan    => 'turnover'
        },
        'Expected data set';

    cmp_deeply $affiliate->get_affiliate_info(),
        {
        affiliate_loginid => $client->loginid,
        affiliate_plan    => 'turnover'
        },
        'Expected data get';

    lives_ok {
        $result = $affiliate->set_affiliate_info({affiliate_plan => 'revenue_share'});
    }
    'Can set affiliate plan turnover';

    cmp_deeply $result,
        {
        affiliate_loginid => $client->loginid,
        affiliate_plan    => 'revenue_share'
        },
        'Expected data set';

    cmp_deeply $affiliate->get_affiliate_info(),
        {
        affiliate_loginid => $client->loginid,
        affiliate_plan    => 'revenue_share'
        },
        'Expected data get';
};

done_testing;
