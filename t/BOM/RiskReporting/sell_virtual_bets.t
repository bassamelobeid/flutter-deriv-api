#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::Exception;
use Test::MockModule;

use Date::Utility;

use BOM::Test::Helper::Client qw(top_up);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Transaction;

use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
use LandingCompany::Registry;

my %rates = map { $_ => 100 } LandingCompany::Registry::all_currencies();
populate_exchange_rates(\%rates);

use BOM::RiskReporting::MarkedToModel qw/get_expired_virtual_contracts/;

my $top_up_amount = 1000;
my $price         = 25;
my $payout        = 50;
my $symbol        = 'R_100';
my $now           = Date::Utility->new;

my $model       = BOM::RiskReporting::MarkedToModel->new;
my $mock_module = Test::MockModule->new('BOM::RiskReporting::MarkedToModel');

$mock_module->mock(
    'end' => sub {
        return Date::Utility->new->minus_time_interval('5s');
    });
$mock_module->mock(
    'cache_daily_turnover' => sub {
        return;
    });

subtest 'Get database names' => sub {
    my $vr_server_name = $model->vr_server_name;
    is $vr_server_name, 'vr', 'VR server name is correct';

    my $dbnames = $model->production_servers;
    is_deeply($dbnames, ['cr', 'mf', 'mlt', 'mx'], 'Production servers names');
};

subtest 'Settle valid expired virtual contract', \&test_expired_virtual_contracts,
    {
    start          => $now->minus_time_interval('10m'),
    tick           => $now->minus_time_interval('10m'),
    total_credited => 50,
    };

subtest 'Refund invalid expired virtual contract', \&test_expired_virtual_contracts,
    {
    start          => $now->minus_time_interval('3h'),
    tick           => $now->minus_time_interval('2h'),
    total_credited => 25,
    };

sub test_expired_virtual_contracts {
    my $params = shift;
    my ($loginid, $bet_id, $vc) = _create_txn($params->{start}, $params->{tick});
    ok $vc->is_expired, 'Contract is expired';

    my $open_bets_ref = $model->live_open_bets($model->vr_server_name);
    ok exists $open_bets_ref->{$bet_id}, 'The contract is open';
    my $expired_vc = {$bet_id => $open_bets_ref->{$bet_id}};

    my $contracts;
    lives_ok { $contracts = get_expired_virtual_contracts($expired_vc) } 'We should get the list of all expired virtual contracts';
    ok exists $contracts->{$loginid}{$bet_id}, 'Expired virtual contract must be returned as open contract';

    my $results = $model->sell_expired_contracts($contracts, []);
    is(@$results, 1, 'One client had expired contracts');
    my $sell_result = @$results[0];
    is($sell_result->{number_of_sold_bets}, 1, 'One contract must be sold');
    is_deeply($sell_result->{failures}, [], 'No failures');
    is($sell_result->{total_credited}, $params->{total_credited}, 'Client credit updated');
    is($sell_result->{skip_contract}, 0, 'No contract is skipped');
}

sub _create_txn {
    my ($date_start, $tick_date) = @_;

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
    my $account = $client->set_default_account('USD');

    top_up($client, $client->currency, $top_up_amount);

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $tick_date->epoch + 1, $symbol], [101, $tick_date->epoch + 2, $symbol]);

    my $contract = produce_contract({
        bet_type     => 'CALL',
        underlying   => $symbol,
        date_start   => $date_start,
        barrier      => 'S0P',
        duration     => '1t',
        currency     => 'USD',
        payout       => $payout,
        date_pricing => $now,
    });

    my $txn_buy = BOM::Transaction->new({
        contract      => $contract,
        amount_type   => 'payout',
        client        => $client,
        price         => $price,
        purchase_date => $contract->date_start,
    });
    $txn_buy->buy(skip_validation => 1);
    my $bet_id = $txn_buy->transaction_details->{financial_market_bet_id};

    return ($client->{loginid}, $bet_id, $contract);
}

done_testing();
