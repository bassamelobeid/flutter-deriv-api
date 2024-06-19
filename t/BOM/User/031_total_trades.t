#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Time::Moment;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw( create_client top_up);
use BOM::Test::Helper::ExchangeRates           qw(populate_exchange_rates);
use BOM::Database::Helper::FinancialMarketBet;
use ExchangeRates::CurrencyConverter qw(in_usd);
use Date::Utility;

populate_exchange_rates({'BTC' => 1.00});

my $minus_7_months = Date::Utility->new->truncate_to_day->minus_time_interval('7mo')->db_timestamp;
my $minus_6_months = Date::Utility->new->truncate_to_day->minus_time_interval('6mo')->db_timestamp;
my $minus_5_months = Date::Utility->new->truncate_to_day->minus_time_interval('5mo')->db_timestamp;

# this is to set the purchase_time < start_time, expiry_time and settlement_time
my $start_expiry_settlement_t = Date::Utility->new->truncate_to_day->minus_time_interval('1mo')->db_timestamp;

subtest "user total trades" => sub {

    my $user = BOM::User->create(
        email    => 'user1@test.com',
        password => 'test',
    );

    top_up my $usd_client = create_client, 'USD', 11, 'ewallet';

    my $btc_client = create_client;
    my $account    = $btc_client->set_default_account('BTC');

    $user->add_client($usd_client);
    $user->add_client($btc_client);

    top_up $btc_client, 'BTC', 10, 'crypto_cashier';

    is 0, $user->total_trades($minus_6_months), 'No trades';

    my $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
            type            => 'fmb_higher_lower',
            account_id      => $account->id,
            buy_price       => 3,
            source          => 1,
            purchase_time   => $minus_7_months,
            start_time      => $start_expiry_settlement_t,
            expiry_time     => $start_expiry_settlement_t,
            settlement_time => $start_expiry_settlement_t

    });

    my $account_data = {
        client_loginid => $btc_client->loginid,
        currency_code  => 'BTC',
    };

    my $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new({
        account_data => $account_data,
        bet          => $fmb,
        db           => $account->db,
    });

    $fmb_helper->bet_data->{quantity} = 1;
    $fmb_helper->buy_bet;

    is 0, $user->total_trades($minus_6_months), 'No trades in the past six months';

    $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type            => 'fmb_higher_lower',
        account_id      => $account->id,
        buy_price       => 4,
        source          => 1,
        purchase_time   => $minus_5_months,
        start_time      => $start_expiry_settlement_t,
        expiry_time     => $start_expiry_settlement_t,
        settlement_time => $start_expiry_settlement_t
    });

    $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new({
        account_data => $account_data,
        bet          => $fmb,
        db           => $account->db,
    });

    is 4, $user->total_trades($minus_6_months), 'Correct trade amount for the past 6 months';
};

done_testing;
