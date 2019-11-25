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
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
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

    my $transaction_hash1 = "abcdefgh";
    my $transaction_hash2 = "dddddddd";

    my $transaction = Net::Async::Blockchain::Transaction->new(
        currency => 'LTC',
        hash     => $transaction_hash1,
        to       => 'abc',
        type     => 'receive',
        amount   => 0,
        block    => 10,
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

    my $btc_address2;
    lives_ok {
        $btc_address2 = $helper->get_deposit_address;
    }
    'survived get_deposit_address 2';

    $transaction->{to} = $btc_address;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Invalid currency";

    ($transaction->{currency}, $transaction->{fee_currency}) = ('BTC', 'BTC');

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Amount is zero";

    $transaction->{amount} = 0.1;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, 1, "Correct status";

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Can't set pending a transaction already pending";

    $transaction->{hash}   = $transaction_hash2;
    $transaction->{amount} = 0.2;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, 1, "Able to set pending a transaction to the same address with an different hash";

    $transaction->{address} = $btc_address2;
    is $response, 1, "Able to set pending a the same transaction to two different addresses";

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Can't set pending a transaction already pending";

    my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
    my $dbic = $clientdb->db->dbic;

    my $start = Time::HiRes::time;
    my $rows  = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{SELECT * FROM payment.ctc_find_deposit_pending_by_currency(?)});
            $sth->execute('BTC');
            return $sth->fetchall_arrayref({});
        });

    my @address_entries = grep { $_->{address} eq $btc_address } $rows->@*;

    is @address_entries, 2, "correct number of pending transactions";

    my @tx1 = grep { $_->{blockchain_txn} eq $transaction_hash1 } @address_entries;
    is @tx1, 1, "Correct hash for the first deposit";
    my @tx2 = grep { $_->{blockchain_txn} eq $transaction_hash2 } @address_entries;
    is @tx2, 1, "Correct hash for the second deposit";

    my $currency = BOM::CTC::Currency->new(
        currency_code => $transaction->{currency},
        broker_code   => 'CR'
    );
    is $currency->get_latest_checked_block('deposit'), 10, "correct latest block number got";
};

done_testing;

