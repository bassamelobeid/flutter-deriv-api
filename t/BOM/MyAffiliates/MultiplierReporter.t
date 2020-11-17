#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More (tests => 2);
use Test::Warnings;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::MyAffiliates::MultiplierReporter;
use YAML::XS qw(LoadFile);
use BOM::Config::Runtime;
use Test::Deep;

use constant {
    DUPLICATE => 4    # Unit Test Database duplicate bug
};

my $now = '2020-09-14 08:00:00';

my $app_config                 = BOM::Config::Runtime->instance->app_config;
my $financial_trade_commission = $app_config->get('quants.multiplier_affiliate_commission.financial');

$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
$app_config->set({'quants.multiplier_affiliate_commission.financial'     => 0.3});
$app_config->set({'quants.multiplier_affiliate_commission.non_financial' => 0.4});

my $trade_commission = {
    financial     => $app_config->get('quants.multiplier_affiliate_commission.financial'),
    non_financial => $app_config->get('quants.multiplier_affiliate_commission.non_financial')};

my $dc_commission = LoadFile('/home/git/regentmarkets/bom-config/share/default_multiplier_config.yml')->{common};

# Parameters are defined in bom-test/data/market_unit_test.yml

my $buy_price                    = 10;
my $forex_commission             = 0.2;
my $synthetic_commission         = 0.1;
my $forex_cancellation_price     = 5;
my $synthetic_cancellation_price = 2;
my $forex_multiplier             = 50;
my $synthetic_multiplier         = 100;

subtest 'Multiple Contracts Commission', sub {

    plan tests => 7;

    my $client_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        loginid            => 'CR101',
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

    my $client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        loginid            => 'CR102',
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

    my $client_3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        loginid     => 'CR103',
        broker_code => 'CR',
    });

    $client_3->payment_legacy_payment(
        currency         => 'USD',
        amount           => 10000,
        remark           => 'top up',
        payment_type     => 'credit_debit_card',
        transaction_time => $now,
        payment_time     => $now,
        source           => 1,
    );

    my $reporter = BOM::MyAffiliates::MultiplierReporter->new(
        brand           => Brands->new(),
        processing_date => Date::Utility->new($now));

    buy_contract($client_1, 'synthetic', 0);

    my $output = $reporter->computation();

    my $expected_output = {
        $client_1->{loginid} => {
            commission       => $buy_price * $synthetic_multiplier * $synthetic_commission * $trade_commission->{non_financial} * DUPLICATE,
            trade_commission => $buy_price * $synthetic_multiplier * $synthetic_commission * DUPLICATE
        }};

    cmp_deeply($output, $expected_output, 'Client 1 : Non-financial contract without DC');

    buy_contract($client_1, 'synthetic', 0);

    $output = $reporter->computation();

    $expected_output->{$client_1->{loginid}}{commission} +=
        $buy_price * $synthetic_multiplier * $synthetic_commission * $trade_commission->{non_financial} * DUPLICATE;
    $expected_output->{$client_1->{loginid}}{trade_commission} += $buy_price * $synthetic_multiplier * $synthetic_commission * DUPLICATE;

    cmp_deeply($output, $expected_output, 'Client 1 : Non-financial contract without DC');

    buy_contract($client_1, 'synthetic', 1);

    $output = $reporter->computation();

    $expected_output->{$client_1->{loginid}}{commission} +=
        $synthetic_cancellation_price * $dc_commission->{'R_10'}->{cancellation_commission} * $trade_commission->{non_financial} * DUPLICATE;
    $expected_output->{$client_1->{loginid}}{trade_commission} +=
        $synthetic_cancellation_price * $dc_commission->{'R_10'}->{cancellation_commission} * DUPLICATE;

    cmp_deeply($output, $expected_output, 'Client 1 : Non-financial contract with DC');

    buy_contract($client_2, 'synthetic', 0);

    $output = $reporter->computation();

    $expected_output->{$client_2->{loginid}}{commission} =
        $buy_price * $synthetic_multiplier * $synthetic_commission * $trade_commission->{non_financial} * DUPLICATE;
    $expected_output->{$client_2->{loginid}}{trade_commission} = $buy_price * $synthetic_multiplier * $synthetic_commission * DUPLICATE;

    cmp_deeply($output, $expected_output, 'Client 2 : Non-financial contract without DC');

    buy_contract($client_2, 'forex', 0);

    $output = $reporter->computation();

    $expected_output->{$client_2->{loginid}}{commission} +=
        $buy_price * $forex_multiplier * $forex_commission * $trade_commission->{financial} * DUPLICATE;
    $expected_output->{$client_2->{loginid}}{trade_commission} += $buy_price * $forex_multiplier * $forex_commission * DUPLICATE;

    cmp_deeply($output, $expected_output, 'Client 2 : Financial contract without DC');

    buy_contract($client_2, 'forex', 1);

    $output = $reporter->computation();

    $expected_output->{$client_2->{loginid}}{commission} +=
        $forex_cancellation_price * $dc_commission->{'frxUSDJPY'}->{cancellation_commission} * $trade_commission->{financial} * DUPLICATE;
    $expected_output->{$client_2->{loginid}}{trade_commission} +=
        $forex_cancellation_price * $dc_commission->{'frxUSDJPY'}->{cancellation_commission} * DUPLICATE;

    cmp_deeply($output, $expected_output, 'Client 2 : Financial contract with DC');

    buy_contract($client_3, 'forex', 1);

    $output = $reporter->computation();

    cmp_deeply($output, $expected_output, 'Client 3 : Non-affiliated');
};

sub buy_contract {

    my ($client, $market, $is_dc) = @_;

    my $account = $client->set_default_account('USD');

    my $args = {
        account_id       => $account->id,
        buy_price        => 10,
        payment_time     => $now,
        transaction_time => $now,
        start_time       => $now,
        source           => 1408,
    };

    if ($is_dc) {
        $args->{type} = 'fmb_multiplier_' . $market . '_with_dc';
    } else {
        $args->{type} = 'fmb_multiplier_' . $market;
    }

    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    return;
}

done_testing();
