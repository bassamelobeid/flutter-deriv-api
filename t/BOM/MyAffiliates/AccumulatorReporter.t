#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Warnings;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase          qw(:init);

use BOM::Config::Runtime;
use BOM::MyAffiliates::AccumulatorReporter;
use Finance::Contract::Longcode qw(shortcode_to_parameters);

use constant {
    DUPLICATE => 4    # Unit Test Database duplicate bug
};

# These values are set in BO.
my $app_config       = BOM::Config::Runtime->instance->app_config;
my $commission_ratio = {
    financial     => $app_config->get('quants.accumulator.affiliate_commission.financial'),
    non_financial => $app_config->get('quants.accumulator.affiliate_commission.non_financial')};

my $mock_reporter = Test::MockModule->new('BOM::MyAffiliates::Reporter');

subtest 'app ids', sub {

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

    my $date     = Date::Utility->new($now);
    my $reporter = BOM::MyAffiliates::AccumulatorReporter->new(
        brand           => Brands->new(),
        processing_date => $date
    );

    my $account    = $client->set_default_account('USD');
    my $short_code = 'ACCU_R_10_10_2_0.01_1_0.0001_' . $date->epoch;
    # buy a contract
    my $args = {
        account_id       => $account->id,
        buy_price        => 10,
        type             => 'fmb_accumulator',
        short_code       => $short_code,
        payment_time     => $now,
        transaction_time => $now,
        start_time       => $now,
        source           => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => undef, include_apps => undef} });
    my $output                 = $reporter->computation();
    my $contract_params        = shortcode_to_parameters($short_code);
    my $trade_commission_value = $contract_params->{amount} * ((1 + $contract_params->{growth_rate})**($contract_params->{growth_start_step}) - 1);
    my $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    my $expected_output        = {
        $client->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};

    is_deeply($output, $expected_output, 'included and excluded app ids are undef');

    my @csv = $reporter->activity();
    is(@csv, 2, 'One row client one row header');

    @csv = grep { my $id = $client->loginid; /$id/ } @csv;
    is(@csv, 1, 'Client is on the list');

    chomp $csv[0];
    my $expected_csv = "2020-09-14,deriv_CR101,0.80,0.32,1.00";
    is_deeply($csv[0], $expected_csv, 'Check if values are correct');

    # excluded app ids
    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => [100], include_apps => undef} });
    $output = $reporter->computation();
    is_deeply($output, {}, 'app id is in the excluded app list');

    @csv = $reporter->activity();
    is(@csv, 0, 'No csv output');

    # included app ids
    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => undef, include_apps => [101]} });
    $output = $reporter->computation();
    is_deeply($output, {}, 'app id is not in the included list');

    @csv = $reporter->activity();
    is(@csv, 0, 'No csv output');

    $mock_reporter->mock('get_apps_by_brand', sub { return {exclude_apps => undef, include_apps => [100]} });
    $output = $reporter->computation();
    is_deeply($output, $expected_output, 'app id is in the included app list');

    @csv = $reporter->activity();
    is(@csv, 2, 'One row client one row header');

    @csv = grep { my $id = $client->loginid; /$id/ } @csv;
    is(@csv, 1, 'Client is on the list');

    chomp $csv[0];
    $expected_csv = "2020-09-14,deriv_CR101,0.80,0.32,1.00";
    is_deeply($csv[0], $expected_csv, 'Check if values are correct');

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
    my $reporter = BOM::MyAffiliates::AccumulatorReporter->new(
        brand           => Brands->new(),
        processing_date => $date
    );

    my $account    = $client_1->set_default_account('USD');
    my $short_code = 'ACCU_R_10_10_2_0.01_1_0.0001_' . $date->epoch;
    # buy a contract
    my $args = {
        account_id       => $account->id,
        buy_price        => 10,
        type             => 'fmb_accumulator',
        short_code       => $short_code,
        payment_time     => $now,
        transaction_time => $now,
        start_time       => $now,
        source           => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    my $output          = $reporter->computation();
    my $contract_params = shortcode_to_parameters($short_code);

    my $trade_commission_value  = $contract_params->{amount} * ((1 + $contract_params->{growth_rate})**($contract_params->{growth_start_step}) - 1);
    my $commission_value        = $trade_commission_value * $commission_ratio->{non_financial};
    my $client1_expected_output = {
        $client_1->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};

    is_deeply($output, $client1_expected_output, 'Client 1 with 1 contract');

    my @csv = $reporter->activity();
    is(@csv, 2, 'One row client one row header');

    @csv = grep { my $id = $client_1->loginid; /$id/ } @csv;
    is(@csv, 1, 'Client 1 is on the list');

    chomp $csv[0];
    my $expected_csv = "2020-09-16,deriv_CR200,0.80,0.32,1.00";
    is_deeply($csv[0], $expected_csv, 'Check if values are correct');

    $short_code = 'ACCU_R_10_10_2_0.01_1_0.0001_' . ($date->epoch + 1);
    # buy a contract
    $args = {
        account_id       => $account->id,
        buy_price        => 10,
        type             => 'fmb_accumulator',
        short_code       => $short_code,
        payment_time     => $now,
        transaction_time => $now,
        start_time       => $now,
        source           => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output                  = $reporter->computation();
    $client1_expected_output = {
        $client_1->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE * 2,
            commission       => $commission_value * DUPLICATE * 2,
            currency         => 'USD'
        }};

    is_deeply($output, $client1_expected_output, 'Client 1 with 2 contracts');

    @csv = $reporter->activity();
    chomp $csv[1];
    $expected_csv = "2020-09-16,deriv_CR200,1.61,0.64,1.00";
    is_deeply($csv[1], $expected_csv, 'Check if values are correct');

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

    $account    = $client_2->set_default_account('USD');
    $short_code = 'ACCU_R_10_10_3_0.01_1_0.0001_' . $date->epoch;
    # buy a contract
    $args = {
        account_id       => $account->id,
        buy_price        => 10,
        type             => 'fmb_accumulator',
        short_code       => $short_code,
        payment_time     => $now,
        transaction_time => $now,
        start_time       => $now,
        source           => 100,
    };
    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb($args);

    $output                 = $reporter->computation();
    $contract_params        = shortcode_to_parameters($short_code);
    $trade_commission_value = $contract_params->{amount} * ((1 + $contract_params->{growth_rate})**($contract_params->{growth_start_step}) - 1);
    $commission_value       = $trade_commission_value * $commission_ratio->{non_financial};
    my $client2_expected_output = {
        $client_2->{loginid} => {
            trade_commission => $trade_commission_value * DUPLICATE,
            commission       => $commission_value * DUPLICATE,
            currency         => 'USD'
        }};

    my $expected_output = {
        $client_1->{loginid} => $client1_expected_output->{$client_1->{loginid}},
        $client_2->{loginid} => $client2_expected_output->{$client_2->{loginid}}};

    is_deeply($output, $expected_output, 'Two clients with contracts');

    @csv = $reporter->activity();
    is(@csv, 3, 'Two row clients one row header');

    @csv = $reporter->activity();
    @csv = grep { my $id = $client_1->loginid; /$id/ } @csv;
    is(@csv, 1, 'Client 1 is on the list');

    @csv = $reporter->activity();
    @csv = grep { my $id = $client_2->loginid; /$id/ } @csv;
    is(@csv, 1, 'Client 2 is on the list');

    @csv = $reporter->activity();
    @csv = @csv[1 .. $#csv];
    @csv = map { chomp $_; $_ } @csv;
    my @expected_csv = ("2020-09-16,deriv_CR200,1.61,0.64,1.00", "2020-09-16,deriv_CR201,1.21,0.48,1.00");
    is_deeply(\@csv, \@expected_csv, 'Check if values are correct');
};

done_testing();
