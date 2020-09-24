#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client top_up);
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::Database::Helper::FinancialMarketBet;
use ExchangeRates::CurrencyConverter qw(in_usd);

populate_exchange_rates({'BTC' => 10732.6910});

subtest "suspicious" => sub {

    my $user = BOM::User->create(
        email    => 'user1@test.com',
        password => 'test',
    );

    top_up my $usd_client = create_client, 'USD', 11, 'ewallet';

    my $btc_client = create_client;
    my $account    = $btc_client->set_default_account('BTC');

    $user->add_client($usd_client);
    $user->add_client($btc_client);

    is $user->total_deposits(), 11, 'correct total deposits';

    top_up $btc_client, 'BTC', 10, 'crypto_cashier';

    is $user->total_deposits(), 107337.91, 'correct total deposits';

    is 1, $user->is_crypto_withdrawal_suspicious(), 'Suspicious - No trades';

    my $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type       => 'fmb_higher_lower',
        account_id => $account->id,
        buy_price  => 1,
        source     => 1,
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

    is 1, $usd_client->user->is_crypto_withdrawal_suspicious(), 'Suspicious - Trading volume less than 25% of the deposit and deposit with CC';

    $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type       => 'fmb_higher_lower',
        account_id => $account->id,
        buy_price  => 4,
        source     => 1,
    });

    $fmb_helper = BOM::Database::Helper::FinancialMarketBet->new({
        account_data => $account_data,
        bet          => $fmb,
        db           => $account->db,
    });

    is 0, $usd_client->user->is_crypto_withdrawal_suspicious(), 'Suspicious - Trading volume more than 25% of the deposit and deposit with CC';
};

done_testing;

