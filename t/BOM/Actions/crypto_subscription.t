#!/usr/bin/env perl

use strict;
use warnings;

use Test::Exception;
use Test::Fatal;
use Test::More;
use Test::Warnings;
use Test::MockModule;

use Net::Async::Blockchain::Transaction;
use BOM::Event::Actions::CryptoSubscription;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use BOM::CTC::Helper;
use BOM::CTC::Currency::LTC;
use BOM::CTC::Currency::BTC;

my $mock_ltc = Test::MockModule->new('BOM::CTC::Currency::LTC');
$mock_ltc->mock(
    is_valid_address => sub {
        return 1;
    });
my $mock_btc = Test::MockModule->new('BOM::CTC::Currency::BTC');
$mock_btc->mock(
    is_valid_address => sub {
        return 1;
    },
    get_new_address => sub {
        return 'mtXWDB6k5yC5v7TcwKZHB89SUp85yCKshy',;
    });

subtest "change_address_status" => sub {
    my $transaction = Net::Async::Blockchain::Transaction->new(
        currency => 'LTC',
        hash     => 'abcdefgh',
        to       => ['abc', 'def'],
        type     => 'receive',
        amount   => 0,
    );

    my $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Nothing found in the database";

    my $client = create_client();
    $client->set_default_account('BTC');
    my $helper = BOM::CTC::Helper->new(client => $client);

    my $btc_address;
    lives_ok {
        $btc_address = $helper->get_deposit_address;
    }
    'survived get_deposit_address';

    $transaction->{to} = [$btc_address];

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Invalid currency";

    ($transaction->{currency}, $transaction->{fee_currency}) = ('BTC', 'BTC');

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Amount is zero";

    $transaction->{amount} = 0.1;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, 1, "Correct status";
};

done_testing;

