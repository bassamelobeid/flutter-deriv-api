use strict;
use warnings;

use Test::More;
use Test::Deep;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

subtest 'get_self_exclusion_audit' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    cmp_deeply $client->get_self_exclusion_audit, [], 'empty array for new client';

    $client->set_exclusion->max_open_bets(1);
    $client->set_exclusion->max_turnover(200);
    $client->set_exclusion->max_7day_turnover(500);
    $client->set_exclusion->max_30day_turnover(12000);
    $client->set_exclusion->max_balance(20000);
    $client->set_exclusion->session_duration_limit(100000);
    $client->save;

    cmp_deeply $client->get_self_exclusion_audit,
        [{
            prev_value    => undef,
            changed_stamp => re('.*'),
            cur_value     => '20000',
            changed_by    => 'system',
            field         => 'max_balance'
        },
        {
            changed_by    => 'system',
            field         => 'max_turnover',
            prev_value    => undef,
            changed_stamp => re('.*'),
            cur_value     => '200'
        },
        {
            prev_value    => undef,
            cur_value     => '1',
            changed_stamp => re('.*'),
            field         => 'max_open_bets',
            changed_by    => 'system'
        },
        {
            changed_stamp => re('.*'),
            cur_value     => '100000',
            prev_value    => undef,
            changed_by    => 'system',
            field         => 'session_duration_limit'
        },
        {
            changed_by    => 'system',
            field         => 'max_7day_turnover',
            changed_stamp => re('.*'),
            cur_value     => '500',
            prev_value    => undef
        },
        {
            field         => 'max_30day_turnover',
            changed_by    => 'system',
            cur_value     => '12000',
            changed_stamp => re('.*'),
            prev_value    => undef
        }
        ],
        'Expected self exclusion details from audit table';
};

done_testing();
