#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);

use Format::Util::Numbers qw/formatnumber/;
use BOM::Transaction;
use Date::Utility;
use BOM::Product::ContractFactory qw(produce_contract);

my $client = create_client('CR');
top_up $client, 'USD', 5000;
my $underlying_symbol = 'R_50';

subtest 'app_markup_transaction' => sub {
    my $now = Date::Utility->new;

    BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100.01, $now->epoch - 1, $underlying_symbol],
        [100, $now->epoch, $underlying_symbol]);

    my $contract_args = {
        bet_type              => 'CALL',
        underlying            => $underlying_symbol,
        barrier               => 'S0P',
        date_start            => $now,
        date_pricing          => $now,
        duration              => '15m',
        currency              => 'USD',
        payout                => 100,
        app_markup_percentage => 0,
    };

    my $contract = produce_contract($contract_args);

    my $txn = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy";
    cmp_ok $txn->contract->app_markup_dollar_amount(), '==', 0, "no app markup";

    my $app_markup_percentage = 1;
    $contract_args->{app_markup_percentage} = $app_markup_percentage;
    $contract = produce_contract($contract_args);

    $txn = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy";
    cmp_ok $txn->contract->app_markup_dollar_amount(), '==', $app_markup_percentage / 100 * $contract->payout,
        "transaction app_markup is app_markup_percentage of contract payout for payout amount_type";

    delete $contract_args->{payout};
    $contract_args->{stake}                 = 100;
    $contract_args->{app_markup_percentage} = 0;
    $contract                               = produce_contract($contract_args);
    my $contract_payout = $contract->payout;

    $txn = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy for stake";
    cmp_ok $txn->contract->app_markup_dollar_amount(), '==', 0, "no app markup for stake";

    $app_markup_percentage                  = 2;
    $contract_args->{app_markup_percentage} = $app_markup_percentage;
    $contract                               = produce_contract($contract_args);

    $txn = BOM::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => $contract->ask_price,
        purchase_date => $now,
        amount_type   => 'payout',
    });
    is $txn->buy(skip_validation => 1), undef, "no error in transaction buy for stake";
    is $txn->contract->app_markup_dollar_amount(), formatnumber('amount', 'USD', $txn->payout * $app_markup_percentage / 100),
        "in case of stake contract, app_markup is app_markup_percentage of final payout i.e transaction payout";
    cmp_ok $txn->payout, "<", $contract_payout, "payout after app_markup_percentage is less than actual payout";
};

done_testing();
