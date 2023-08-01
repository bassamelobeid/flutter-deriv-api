#!perl

use strict;
use warnings;
use Test::More (tests => 21);
use Test::Warnings;
use Test::Exception;
use BOM::Database::DataMapper::MyAffiliates;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase          qw(:init);
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Database::DataMapper::FinancialMarketBet;

my $myaff_data_mapper;

lives_ok {
    $myaff_data_mapper = BOM::Database::DataMapper::MyAffiliates->new({
        'broker_code' => 'FOG',
        'operation'   => 'collector',
    });
}
'Expect to initialize the myaffilaites data mapper';

my $activities;
$activities = $myaff_data_mapper->get_clients_activity({'date' => Date::Utility->new('2011-03-09')->date_yyyymmdd});

cmp_ok($activities->{'MX1001'}->{'withdrawals'},        '==', 100,          'Check if activity withdrawals is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'deposits'},           '==', 4200,         'Check if activity deposits is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'pnl'},                '==', 0,            'Check if activity pnl is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'turnover_others'},    '==', 0,            'Check if activity turnover_others is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'turnover_intradays'}, '==', 0,            'Check if turnover_intradays factors is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'first_funded_date'},  'eq', '2011-03-09', 'Check if activity first_funded_date is correct for myaffiliate');

$activities = $myaff_data_mapper->get_clients_activity({'date' => Date::Utility->new('2017-03-09')->date_yyyymmdd});

cmp_ok($activities->{'MX1001'}->{'withdrawals'},        '==', 0,            'Check if activity withdrawals is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'deposits'},           '==', 0,            'Check if activity deposits is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'pnl'},                '==', 0,            'Check if activity pnl is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'turnover_others'},    '==', 0,            'Check if activity turnover_others is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'turnover_intradays'}, '==', 0,            'Check if turnover_intradays factors is correct for myaffiliate');
cmp_ok($activities->{'MX1001'}->{'first_funded_date'},  'eq', '2011-03-09', 'Check if activity first_funded_date is correct for myaffiliate');

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code        => 'CR',
    myaffiliates_token => 'dummy_affiliate_token',
});
my $account = $client->set_default_account('USD');

$client->payment_legacy_payment(
    currency         => 'USD',
    amount           => 1000,
    remark           => 'here is money',
    payment_type     => 'credit_debit_card',
    transaction_time => '2011-03-08 12:59:59',
    payment_time     => '2011-03-08 12:59:59',
    source           => 1,
);

subtest 'get trading activity' => sub {
    my $date = '2011-03-08 12:59:59';

    # before buying any contract
    my $trading_activities = $myaff_data_mapper->get_trading_activity({'date' => $date});
    ok !@$trading_activities, 'no trading activity';

    # buy contract
    my $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type             => 'fmb_higher_lower',
        account_id       => $account->id,
        buy_price        => 456,
        sell_price       => 40,
        payment_time     => $date,
        transaction_time => $date,
        start_time       => $date,
        expiry_time      => $date,
        source           => 1,
    });

    $trading_activities = $myaff_data_mapper->get_trading_activity({'date' => $date});
    ok @$trading_activities, 'have some trading activities';
};

subtest 'get multiplier commission' => sub {
    my $date = '2020-09-14 08:00:00';

    # before buying multiplier contract
    my $trading_activities = $myaff_data_mapper->get_multiplier_commission({'date' => $date});
    ok !@$trading_activities, 'no multiplier contracts trading activity';

    # buy multiplier contract
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        account_id       => $account->id,
        buy_price        => 10,
        payment_time     => $date,
        transaction_time => $date,
        start_time       => $date,
        source           => 1,
        type             => 'fmb_multiplier_forex',
    });

    $trading_activities = $myaff_data_mapper->get_multiplier_commission({'date' => $date});
    ok @$trading_activities, 'have some multiplier contracts trading activities';
};

subtest 'get accumulator commission' => sub {
    my $date = '2020-09-14 08:00:00';

    # before buying accumulator contract
    my $trading_activities = $myaff_data_mapper->get_contracts_with_spread_commission({'date' => $date, 'bet_class' => 'accumulator'});
    ok !@$trading_activities, 'no accumulator contracts trading activity';

    my $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_accumulator_buy_only',
        payment_time      => $date,
        transaction_time  => $date,
        start_time        => $date,
        purchase_time     => $date,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $trading_activities = $myaff_data_mapper->get_contracts_with_spread_commission({'date' => $date, 'bet_class' => 'accumulator'});
    ok @$trading_activities, 'have some accumulator contracts trading activities';
};

subtest 'get turbos commission' => sub {
    my $date = '2020-09-14 08:00:00';

    # before buying accumulator contract
    my $trading_activities = $myaff_data_mapper->get_contracts_with_spread_commission({'date' => $date, 'bet_class' => 'turbos'});
    ok !@$trading_activities, 'no turbos contracts trading activity';

    my $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_turbos_buy_only',
        payment_time      => $date,
        transaction_time  => $date,
        start_time        => $date,
        purchase_time     => $date,
        ask_spread        => 5,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $trading_activities = $myaff_data_mapper->get_contracts_with_spread_commission({'date' => $date, 'bet_class' => 'turbos'});
    ok @$trading_activities, 'have some turbos contracts trading activities';
};

subtest 'get vanilla commission' => sub {
    my $date = '2020-09-14 08:00:00';

    # before buying vanilla contract
    my $trading_activities = $myaff_data_mapper->get_contracts_with_spread_commission({'date' => $date, 'bet_class' => 'vanilla'});
    ok !@$trading_activities, 'no vanilla contracts trading activity';

    my $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_vanillas_buy_only',
        payment_time      => $date,
        transaction_time  => $date,
        start_time        => $date,
        purchase_time     => $date,
        ask_spread        => 5,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $trading_activities = $myaff_data_mapper->get_contracts_with_spread_commission({'date' => $date, 'bet_class' => 'vanilla'});
    ok @$trading_activities, 'have some vanilla contracts trading activities';
};

subtest 'get lookback commission' => sub {
    my $date = '2020-09-14 08:00:00';

    # before buying lookback contract
    my $trading_activities = $myaff_data_mapper->get_lookback_activity({'date' => '2020-09-16 08:00:00'});
    ok !@$trading_activities, 'no lookback contracts trading activity';

    # buy lookback contract
    my $start_date = Date::Utility->new($date)->plus_time_interval('1h')->datetime;
    my $end_date   = Date::Utility->new($date)->plus_time_interval('6h')->datetime;

    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type             => 'fmb_lookback_option',
        account_id       => $account->id,
        purchase_time    => $start_date,
        transaction_time => $start_date,
        start_time       => $start_date,
        expiry_time      => $end_date,
        settlement_time  => $end_date,
        source           => 1,
    });

    $trading_activities = $myaff_data_mapper->get_lookback_activity({'date' => $date});
    ok @$trading_activities, 'have some lookback contracts trading activities';
};

subtest 'get monthly exchange rate' => sub {
    my $monthly_exchange_rate = $myaff_data_mapper->get_monthly_exchange_rate({
        source_currency => 'USD',
        month           => 1,
        year            => 2000
    });
    is sprintf("%.2f", $monthly_exchange_rate->[0][0]), '1.00', 'USD to USD exchange rate should be 1';
};
