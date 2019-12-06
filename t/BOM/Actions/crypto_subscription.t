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
use BOM::Test;
use BOM::CTC::Helper;
use BOM::CTC::Currency::LTC;
use BOM::CTC::Currency::BTC;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_events_redis);
use BOM::Platform::Event::Emitter;
use IO::Async::Loop;
use BOM::Event::Services;

initialize_events_redis();

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
my $mock_subscription = Test::MockModule->new('BOM::Event::Actions::CryptoSubscription');
my $mock_platform     = Test::MockModule->new('BOM::Platform::Event::Emitter');

subtest "change_address_status" => sub {

    my $transaction_hash1 = "427d42cfa0717e8d4ce8b453de74cc84f3156861df07173876f6cfebdcbc099a";
    my $transaction_hash2 = "adf0e2b9604813163ba6eb769a22174c68ace6349ddd1a79d4b10129f8d35924";
    my $transaction_hash3 = "55adac01630d9f836b4075128190887c54ba56c5e0d991e90ecb7ebd487a0526";

    my $transaction = {
        currency => 'LTC',
        hash     => $transaction_hash1,
        to       => ['36ob9DZcMYQkRHGFNJHjrEKP7N9RyTihHW'],
        type     => 'receive',
        amount   => 0,
        block    => 10,
    };

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

    $transaction->{to} = [$btc_address];

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

    $mock_subscription->mock(
        update_transaction_status_to_pending => sub {
            return undef;
        });

    $mock_platform->mock(
        _write_connection => sub {
            my $config = BOM::Config::RedisReplicated::redis_config('events', 'write');
            return RedisDB->new(
                host => $config->{host},
                port => $config->{port},
            );
        });

    $transaction->{hash}   = $transaction_hash3;
    $transaction->{amount} = 0.5;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Error inserting transaction in the database";

    my $new_transaction_event = BOM::Platform::Event::Emitter::get("GENERIC_EVENTS_QUEUE");
    is_deeply $new_transaction_event->{details}, $transaction, 'Event found after emit it again';

    $mock_subscription->unmock_all();

    # These are one of the few transactions we had failing in production we are adding
    # them to test to make sure we are not really not failing to insert them in the database
    # for any other reason than a connection issue.
    my $transactions = [{
            currency => 'BTC',
            amount   => Math::BigFloat->new(0.00027722)->bstr(),
            address  => '3DypDdeN37TCnMsiqrC5QtRQzQXLrXZY9f',
            hash     => '77d11b3ae59cc4dc3882d042ac68225edaf28a2cc41c2184f6b3e8e3c07fb1f9',
        },
        {
            currency => 'BTC',
            amount   => Math::BigFloat->new(0.00479958)->bstr(),
            address  => '35hTQCgeiNerjgy4LGW1jG5Nx9CawdjutG',
            hash     => '9e0109559805a209234dae70c1005e43f23dbef5d10f6de9532260c39a05fdcd',
        },
        {
            currency => 'BTC',
            amount   => Math::BigFloat->new(0.00270685)->bstr(),
            address  => '3KHFGHbBX71PE7V1dawAMPRtHD3U3Bqk7e',
            hash     => '63aa8c1ab1b8cd761527b074a8efa3296e913780a4f712b865c03047931c1cf3',
        }];

    for my $tx ($transactions->@*) {
        my $client = create_client();
        $client->set_default_account('BTC');
        $dbic->run(
            ping => sub {
                my $sth = $_->prepare('SELECT payment.ctc_insert_new_deposit(?, ?, ?, ?, ?)');
                $sth->execute($tx->{address}, $tx->{currency}, $client->loginid, $tx->{fee}, $tx->{hash})
                    or die $sth->errstr;
            });
        $response = BOM::Event::Actions::CryptoSubscription::update_transaction_status_to_pending($tx, $tx->{address});
        is $response, 1, "response ok from the database";
    }

};

done_testing;

