#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Warnings;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase          qw(:init);

use BOM::Config::Runtime;
use BOM::MyAffiliates::ContractsWithSpreadReporter;

use constant {
    DUPLICATE => 4    # Unit Test Database duplicate bug
};

# These values are set in BO.
# Since Turbos are a contract type with spread, we use it as the contract category
my $app_config       = BOM::Config::Runtime->instance->app_config;
my $commission_ratio = {
    financial     => $app_config->get('quants.turbos.affiliate_commission.financial'),
    non_financial => $app_config->get('quants.turbos.affiliate_commission.non_financial')};

my $mock_reporter = Test::MockModule->new('BOM::MyAffiliates::Reporter');

my $now    = '2020-09-14 08:00:00';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    loginid            => 'CR101',
    broker_code        => 'CR',
    myaffiliates_token => 'dummy_affiliate_token',
});

$client->payment_legacy_payment(
    currency         => 'USD',
    amount           => 10000,
    remark           => 'top up',
    payment_type     => 'credit_debit_card',
    transaction_time => $now,
    payment_time     => $now,
    source           => 1,
);
my $date    = Date::Utility->new($now);
my $account = $client->set_default_account('USD');

subtest 'Turbos contracts', sub {

    my $reporter = BOM::MyAffiliates::ContractsWithSpreadReporter->new(
        brand             => Brands->new(),
        processing_date   => $date,
        contract_category => 'turbos'
    );

    my $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_turbos_buy_only',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        ask_spread        => 5,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => undef, include_apps => undef} });
    my $output                 = $reporter->computation();
    my $trade_commission_value = 5;
    my $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    my $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};

    is_deeply($output, $expected_output, 'commission on buy is correct');

    $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_turbos_buy_sell',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        sell_time         => $now,
        sell_price        => 1,
        ask_spread        => 5,
        bid_spread        => 2,
        is_expired        => 0,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output                 = $reporter->computation();
    $trade_commission_value = 12;
    $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};
    is_deeply($output, $expected_output, 'commission on buy/sell is correct when contract is not expired');

    $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_turbos_buy_sell',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        sell_time         => $now,
        sell_price        => 1,
        ask_spread        => 5,
        bid_spread        => 2,
        is_expired        => 1,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output                 = $reporter->computation();
    $trade_commission_value = 17;
    $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};
    is_deeply($output, $expected_output, 'commission on buy/sell is correct when contract is expired');

    # excluded app ids
    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => [100], include_apps => undef} });
    $output = $reporter->computation();
    is_deeply($output, {}, 'app id is in the excluded app list');

    # included app ids
    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => undef, include_apps => [101]} });
    $output = $reporter->computation();
    is_deeply($output, {}, 'app id is not in the included list');

    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => undef, include_apps => [100]} });
    $output = $reporter->computation();
    is_deeply($output, $expected_output, 'app id is in the included app list');

};

subtest 'Vanillas contracts', sub {

    my $reporter = BOM::MyAffiliates::ContractsWithSpreadReporter->new(
        brand             => Brands->new(),
        processing_date   => $date,
        contract_category => 'vanilla'
    );

    my $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_vanillas_buy_only',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        ask_spread        => 5,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => undef, include_apps => undef} });
    my $output                 = $reporter->computation();
    my $trade_commission_value = 5;
    my $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    my $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};

    is_deeply($output, $expected_output, 'commission on buy is correct');

    $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_vanillas_buy_sell',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        sell_time         => $now,
        sell_price        => 1,
        ask_spread        => 5,
        bid_spread        => 2,
        is_expired        => 0,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output                 = $reporter->computation();
    $trade_commission_value = 12;
    $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};
    is_deeply($output, $expected_output, 'commission on buy/sell is correct when contract is not expired');

    $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_vanillas_buy_sell',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        sell_time         => $now,
        sell_price        => 1,
        ask_spread        => 5,
        bid_spread        => 2,
        is_expired        => 1,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output                 = $reporter->computation();
    $trade_commission_value = 17;
    $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};
    is_deeply($output, $expected_output, 'commission on buy/sell is correct when contract is expired');

};

subtest 'Accumulator contracts', sub {

    my $reporter = BOM::MyAffiliates::ContractsWithSpreadReporter->new(
        brand             => Brands->new(),
        processing_date   => $date,
        contract_category => 'accumulator'
    );
    # No commission on buy for accumulator contracts
    # Commission is charged both on expired and manually sold contracts
    my $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_accumulator_buy_only',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    my $output                 = $reporter->computation();
    my $trade_commission_value = 0;
    my $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    my $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};
    is_deeply($output, $expected_output, 'no commission on buy for accumulator contracts');

    $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_accumulator_buy_sell',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        sell_time         => $now,
        sell_price        => 1,
        bid_spread        => 2,
        is_expired        => 0,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output                 = $reporter->computation();
    $trade_commission_value = 2;
    $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};
    is_deeply($output, $expected_output, 'commission on sell when contract is sold but not expired');

    $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_10',
        type              => 'fmb_accumulator_buy_sell',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        sell_time         => $now,
        sell_price        => 1,
        bid_spread        => 2,
        is_expired        => 1,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output                 = $reporter->computation();
    $trade_commission_value = 4;
    $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};
    is_deeply($output, $expected_output, 'commission on sell when contract is sold and expired');

};

subtest 'Multiple Contracts Commission', sub {

    my $now = '2020-09-16 08:00:00';
    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => undef, include_apps => undef} });

    my $client_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        loginid            => 'CR200',
        broker_code        => 'CR',
        myaffiliates_token => 'dummy_affiliate_token',
    });

    $client_1->payment_legacy_payment(
        currency         => 'USD',
        amount           => 10000,
        remark           => 'top up',
        payment_type     => 'credit_debit_card',
        transaction_time => $now,
        payment_time     => $now,
        source           => 1,
    );

    my $date     = Date::Utility->new($now);
    my $reporter = BOM::MyAffiliates::ContractsWithSpreadReporter->new(
        brand             => Brands->new(),
        processing_date   => $date,
        contract_category => 'turbos'
    );

    my $account = $client_1->set_default_account('USD');
    # buy a contract
    my $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'R_100',
        type              => 'fmb_turbos_buy_only',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        ask_spread        => 5,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    my $output                               = $reporter->computation();
    my $trade_commission_value_non_financial = 5;
    my $commission_value_non_financial       = $trade_commission_value_non_financial * $commission_ratio->{non_financial};
    my $client1_expected_output              = {
        $client_1->{loginid} => {
            trade_commission => $trade_commission_value_non_financial * DUPLICATE,
            commission       => $commission_value_non_financial * DUPLICATE,
            currency         => 'USD'
        }};

    is_deeply($output, $client1_expected_output, 'Client 1 with one non_financial contract');

    # buy a contract
    $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => 'frxAUDCAD',
        type              => 'fmb_turbos_buy_only',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        ask_spread        => 4,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output = $reporter->computation();
    my $trade_commission_value_financial = 4;
    my $commission_value_financial       = $trade_commission_value_financial * $commission_ratio->{financial};
    my $total_trade_commission           = $trade_commission_value_non_financial + $trade_commission_value_financial;
    my $total_commission                 = $commission_value_non_financial + $commission_value_financial;
    $client1_expected_output = {
        $client_1->{loginid} => {
            trade_commission => $total_trade_commission * DUPLICATE,
            commission       => $total_commission * DUPLICATE,
            currency         => 'USD'
        }};

    is_deeply($output, $client1_expected_output, 'Client 1 with one non_financial contract and one financial contract');

    my $client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        loginid            => 'CR201',
        broker_code        => 'CR',
        myaffiliates_token => 'dummy_affiliate_token',
    });

    $client_2->payment_legacy_payment(
        currency         => 'USD',
        amount           => 10000,
        remark           => 'top up',
        payment_type     => 'credit_debit_card',
        transaction_time => $now,
        payment_time     => $now,
        source           => 1,
    );
    $account = $client_2->set_default_account('USD');

    $args = {
        account_id        => $account->id,
        buy_price         => 10,
        underlying_symbol => '1HZ100V',
        type              => 'fmb_turbos_buy_only',
        payment_time      => $now,
        transaction_time  => $now,
        start_time        => $now,
        purchase_time     => $now,
        ask_spread        => 3,
        source            => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output                               = $reporter->computation();
    $trade_commission_value_non_financial = 3;
    $commission_value_non_financial       = $trade_commission_value_non_financial * $commission_ratio->{non_financial};
    my $client2_expected_output = {
        $client_2->{loginid} => {
            trade_commission => $trade_commission_value_non_financial * DUPLICATE,
            commission       => $commission_value_non_financial * DUPLICATE,
            currency         => 'USD'
        }};

    my $expected_output = {
        $client_1->{loginid} => $client1_expected_output->{$client_1->{loginid}},
        $client_2->{loginid} => $client2_expected_output->{$client_2->{loginid}}};

    is_deeply($output, $expected_output, 'Two clients with contracts');

};

done_testing();
