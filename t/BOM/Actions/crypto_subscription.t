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
use List::Util qw(all);
use BOM::Test::Helper::Client qw( create_client top_up);

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

my $user = BOM::User->create(
    email    => 'test@binary.com',
    password => 'abcd'
);

top_up my $client = create_client('CR'), 'ETH', 10;

$user->add_client($client);

my $currency = BOM::CTC::Currency->new(
    currency_code => 'ETH',
    broker_code   => 'CR'
);

my $helper = BOM::CTC::Helper->new(client => $client);

my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
my $dbic = $clientdb->db->dbic;

subtest "change_address_status" => sub {

    my $transaction_hash1 = "427d42cfa0717e8d4ce8b453de74cc84f3156861df07173876f6cfebdcbc099a";
    my $transaction_hash2 = "adf0e2b9604813163ba6eb769a22174c68ace6349ddd1a79d4b10129f8d35924";
    my $transaction_hash3 = "55adac01630d9f836b4075128190887c54ba56c5e0d991e90ecb7ebd487a0526";
    my $transaction_hash4 = "fbbe6717b6946bc426d52c8102dadb59a9250ea5368fb70eea69c152bc7cd4ef";

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

    $mock_btc->mock(
        get_new_address => sub {
            return '2N7MPismngmXWAHzUmyQ2wVG8s81CvqUkQS',;
        });
    my $btc_address2;
    lives_ok {
        $btc_address2 = $helper->get_deposit_address;
    }
    'survived get_deposit_address 2';

    $transaction->{to} = [$btc_address2];
    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, 1, "Able to set pending the same transaction to two different addresses";

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Can't set pending a transaction already pending";

    $transaction->{hash} = $transaction_hash4;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, 1, "Able to set pending two pending transactions to the same address with an different hash";

    my $clientdb = BOM::Database::ClientDB->new({broker_code => 'CR'});
    my $dbic = $clientdb->db->dbic;

    my $start = Time::HiRes::time;
    my $rows  = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{SELECT * FROM payment.ctc_find_deposit_pending_by_currency(?)});
            $sth->execute('BTC');
            return $sth->fetchall_arrayref({});
        });

    my @address_entries = grep { $_->{address} eq $btc_address or $_->{address} eq $btc_address2 } $rows->@*;

    is @address_entries, 4, "correct number of pending transactions";

    my @tx1 = grep { $_->{blockchain_txn} eq $transaction_hash1 } @address_entries;
    is @tx1, 1, "Correct hash for the first deposit";
    my @tx2 = grep { $_->{blockchain_txn} eq $transaction_hash2 } @address_entries;
    is @tx2, 2, "Correct hash for the second deposit";
    my @tx3 = grep { $_->{blockchain_txn} eq $transaction_hash4 } @address_entries;
    is @tx3, 1, "Correct hash for the third pending deposit";

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
            my $config = BOM::Config::Redis::redis_config('events', 'write');
            return RedisDB->new(
                host => $config->{host},
                port => $config->{port},
            );
        });

    $transaction->{hash}   = $transaction_hash3;
    $transaction->{amount} = 0.5;

    my %emitted_event;
    $mock_platform->mock(
        emit => sub {
            my ($notifier, $data) = @_;
            $emitted_event{$notifier} = $data;
            return 1;
        });

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "Error inserting transaction in the database";

    is_deeply $emitted_event{crypto_subscription}, $transaction, 'Event found after emit it again';

    $mock_platform->unmock_all();
    $mock_subscription->unmock_all();

    $rows = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{SELECT * FROM payment.cryptocurrency where currency_code = ? and blockchain_txn = ?});
            $sth->execute('BTC', $transaction->{hash});
            return $sth->fetchall_arrayref({});
        });

    my $is_transacton_inserted = all { $_->{status} eq 'NEW' and $_->{address} eq $btc_address2 } $rows->@*;
    ok $is_transacton_inserted, "Transaction has been inserted with status NEW";

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, 1, "Update the transaction status to pending after emitting it again";

    $response = BOM::Event::Actions::CryptoSubscription::new_crypto_address({loginid => $client->loginid});
    is $response, '2N7MPismngmXWAHzUmyQ2wVG8s81CvqUkQS', 'got new address';

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

    my ($address) = $dbic->run(fixup => sub { $_->selectrow_array('SELECT payment.ctc_find_new_deposit(?, ?)', undef, 'BTC', $client->loginid) });

    is $address, '2N7MPismngmXWAHzUmyQ2wVG8s81CvqUkQS', 'new address created when previous deposit address was marked as pending';

    $response = BOM::Event::Actions::CryptoSubscription::insert_new_deposit($transaction);
    is $response, 0, "no payments found in the database (missing payments parameter)";
    $response = BOM::Event::Actions::CryptoSubscription::insert_new_deposit($transaction, \());
    is $response, 0, "no payments found in the database (empty payments parameter)";

    $transaction->{to}   = "mtXWDB6k5yC5v7TcwKZHB89SUp85yCKshy";
    $transaction->{hash} = "DF00012";

    my $payment = {
        'address'          => $transaction->{to},
        'client_loginid'   => 'CR10000',
        'status'           => 'NEW',
        'currency_code'    => 'BTC',
        'transaction_type' => 'deposit'
    };

    $response = BOM::Event::Actions::CryptoSubscription::insert_new_deposit($transaction, [$payment]);
    is $response, 1, "empty transaction NEW state in the database, do not insert a new row";

    $payment->{blockchain_txn} = $transaction->{hash};

    $response = BOM::Event::Actions::CryptoSubscription::insert_new_deposit($transaction, [$payment]);
    is $response, 1, "same transaction already in the database, do not insert a new row";

    $payment->{blockchain_txn} = "DF00011";

    $response = BOM::Event::Actions::CryptoSubscription::insert_new_deposit($transaction, [$payment]);
    is $response, 1, "Different transaction insert the new row in the database";

    $rows = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare('select * from payment.find_crypto_by_addresses(?::VARCHAR[])');
            $sth->execute([$transaction->{to}]);
            return $sth->fetchall_arrayref({});
        });

    my @rows = $rows->@*;
    my @newtx = grep { $_->{blockchain_txn} eq $transaction->{hash} } @rows;
    is @newtx, 1, "new transaction found in the database";

    $transaction = {
        currency     => 'ETH',
        hash         => "withdrawal_test",
        to           => ['36ob9DZcMYQkRHGFNJHjrEKP7N9RyTihHo'],
        type         => 'send',
        amount       => 10,
        fee          => 247621000000000,
        fee_currency => 'ETH',
        block        => 10,
    };

    _insert_withdrawal_transaction($transaction);

    $response = BOM::Event::Actions::CryptoSubscription::set_transaction_fee($transaction);
    is $response, 1, "Just updating the fee for withdrawal transaction";

    my $updated_transaction = _fetch_withdrawal_transaction($transaction->{hash});
    is $updated_transaction->{fee}, 0.000247621;
};

sub _set_withdrawal_verified {
    my ($address, $currency) = @_;
    my $app_config = BOM::Config::Runtime->instance->app_config;

    $helper->dbic->run(
        fixup => sub {
            $_->selectrow_array('SELECT payment.ctc_set_withdrawal_verified(?, ?, ?::JSONB, ?, ?)',
                undef, $address, $currency, '{"":0}', undef, undef);
        });
}

sub _insert_withdrawal_transaction {
    my $transaction = shift;

    my $address = @{$transaction->{to}}[0];

    $helper->insert_new_withdraw($address, $transaction->{currency}, $client->loginid, $transaction->{amount}, 0);

    _set_withdrawal_verified($address, $transaction->{currency});

    $helper->dbic->run(
        ping => sub { $_->selectrow_array('SELECT payment_id FROM payment.ctc_process_withdrawal(?, ?)', undef, $address, $transaction->{currency}) }
    );

    return $helper->dbic->run(
        ping => sub {
            my $sth = $_->prepare('UPDATE payment.cryptocurrency SET blockchain_txn = ? , status = ? WHERE address = ? AND blockchain_txn IS NULL');
            $sth->execute($transaction->{hash}, 'PROCESSING', $address);
        });
}

sub _fetch_withdrawal_transaction {
    my ($blockchain_txn) = @_;
    return $helper->dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{SELECT * FROM payment.cryptocurrency where blockchain_txn = ?});
            $sth->execute($blockchain_txn);
            return $sth->fetchrow_hashref;
        });
}

subtest "internal_transactions" => sub {

    my $client = create_client();
    $client->set_default_account('BTC');
    my $helper = BOM::CTC::Helper->new(client => $client);

    $mock_btc->mock(
        get_new_address => sub {
            return '3QLeXx1J9Tp3TBnQyHrhVxne9KqkAS9JSR',;
        });

    my $transaction = {
        currency => 'BTC',
        hash     => "ce67323aa74ec562233feb378a895c5abfe97bc0bb8b31b2f72a00ca226f8fa0",
        type     => 'receipt',
        amount   => 0,
        block    => 100,
    };

    my $btc_address;
    lives_ok {
        $btc_address = $helper->get_deposit_address;
    }
    'survived get_deposit_address';

    $transaction->{to} = [$btc_address];

    my $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, undef, "transaction with balance 0 but type eq receipt";

    $transaction->{type} = 'internal';

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, 1, "transaction with balance 0 but type eq internal";

    my $rows = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{SELECT * FROM payment.ctc_find_deposit_pending_by_currency(?)});
            $sth->execute('BTC');
            return $sth->fetchall_arrayref({});
        });

    my @address_entries = grep { $_->{address} eq $btc_address } $rows->@*;

    is @address_entries, 1, "correct number of pending transactions for $btc_address";

    my ($address) = $dbic->run(fixup => sub { $_->selectrow_array('SELECT payment.ctc_find_new_deposit(?, ?)', undef, 'BTC', $client->loginid) });

    is $address, undef, 'no new address created when internal transactions was marked as pending';
};

done_testing;
