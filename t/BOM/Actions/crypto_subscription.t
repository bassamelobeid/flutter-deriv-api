#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Exception;

use Net::Async::Blockchain::Transaction;
use BOM::Event::Actions::CryptoSubscription;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use BOM::Test;
use BOM::CTC::Helper;
use BOM::CTC::Database;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_events_redis);
use BOM::Platform::Event::Emitter;
use IO::Async::Loop;
use BOM::Event::Services;
use List::Util qw(all any);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);

initialize_events_redis();
populate_exchange_rates();

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

my $helper = BOM::CTC::Helper->new(client => $client);

my $dbic = BOM::CTC::Database->new()->cryptodb_dbic();

subtest "change_address_status" => sub {

    my $transaction_hash1 = "427d42cfa0717e8d4ce8b453de74cc84f3156861df07173876f6cfebdcbc099a";
    my $transaction_hash2 = "adf0e2b9604813163ba6eb769a22174c68ace6349ddd1a79d4b10129f8d35924";
    my $transaction_hash3 = "55adac01630d9f836b4075128190887c54ba56c5e0d991e90ecb7ebd487a0526";
    my $transaction_hash4 = "fbbe6717b6946bc426d52c8102dadb59a9250ea5368fb70eea69c152bc7cd4ef";

    my $currency_code      = 'LTC';
    my $currency           = BOM::CTC::Currency->new(currency_code => $currency_code);
    my $reserved_addresses = $currency->get_reserved_addresses();

    my $transaction = {
        currency => $currency_code,
        hash     => $transaction_hash1,
        to       => '36ob9DZcMYQkRHGFNJHjrEKP7N9RyTihHW',
        type     => 'receive',
        amount   => 0,
        block    => 10,
    };

    my $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{error},
        sprintf("%s Transaction not found for address: %s and transaction: %s", $transaction->{currency}, $transaction->{to}, $transaction->{hash}),
        "Nothing found in the database";

    $transaction->{from} = $reserved_addresses->[0];

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{error},
        sprintf(
        "%s Transaction not found but it is a sweep for address: %s and transaction: %s",
        $transaction->{currency},
        $transaction->{to}, $transaction->{hash}
        ),
        "Nothing found in the database but it is a sweep";

    my $client = create_client();
    $client->set_default_account('BTC');
    my $helper = BOM::CTC::Helper->new(client => $client);

    my $btc_address;
    lives_ok {
        $btc_address = $helper->get_deposit_id_and_address;
    }
    'survived get_deposit_id_and_address';

    $transaction->{to} = $btc_address;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{error},
        sprintf("Invalid currency, expecting: %s, received: %s, for transaction: %s", $currency_code, $transaction->{currency}, $transaction->{hash}),
        "Invalid currency";

    $currency_code = 'BTC';
    ($transaction->{currency}, $transaction->{fee_currency}) = ($currency_code, $currency_code);

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{error}, sprintf("Amount is zero for transaction: %s", $transaction->{hash}), "Amount is zero";

    $transaction->{amount} = 0.1;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{status}, 1, "Correct status";

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{error}, sprintf("Address already confirmed by subscription for transaction: %s", $transaction->{hash}),
        "Can't set pending a transaction already pending";

    $transaction->{hash}   = $transaction_hash2;
    $transaction->{amount} = 0.2;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{status}, 1, "Able to set pending a transaction to the same address with an different hash";

    $mock_btc->mock(
        get_new_address => sub {
            return '2N7MPismngmXWAHzUmyQ2wVG8s81CvqUkQS',;
        });
    my $btc_address2;
    my $id2;
    lives_ok {
        ($id2, $btc_address2) = $helper->get_deposit_id_and_address;
    }
    'survived get_deposit_id_and_address 2';

    $transaction->{to} = $btc_address2;
    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{status}, 1, "Able to set pending the same transaction to two different addresses";

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{error}, sprintf("Address already confirmed by subscription for transaction: %s", $transaction->{hash}),
        "Can't set pending a transaction already pending";

    $transaction->{hash} = $transaction_hash4;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{status}, 1, "Able to set pending two pending transactions to the same address with an different hash";

    my $start = Time::HiRes::time;
    my $rows  = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{SELECT * FROM payment.ctc_find_deposit_pending_by_currency_code(?)});
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
    is $response->{error},
        sprintf("Failed to emit event for currency: %s, transaction: %s, error: %s", $currency_code, $transaction->{hash}, "No error returned"),
        "Error inserting transaction in the database";

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
    is $response->{status}, 1, "Update the transaction status to pending after emitting it again";

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
                my $sth = $_->prepare('SELECT payment.ctc_insert_new_deposit_address(?, ?, ?, ?)');
                $sth->execute($tx->{address}, $tx->{currency}, $client->loginid, $tx->{hash})
                    or die $sth->errstr;
            });
        $response = BOM::Event::Actions::CryptoSubscription::update_transaction_status_to_pending($tx, $tx->{address});
        is $response, 1, "response ok from the database";
    }

    my ($address) =
        $dbic->run(
        fixup => sub { $_->selectrow_array('SELECT address from payment.ctc_find_new_deposit_address(?, ?)', undef, 'BTC', $client->loginid) });

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
            my $sth = $_->prepare('select * from payment.find_crypto_deposit_by_address(?::VARCHAR)');
            $sth->execute($transaction->{to});
            return $sth->fetchall_arrayref({});
        });

    my @rows  = $rows->@*;
    my @newtx = grep { $_->{blockchain_txn} eq $transaction->{hash} } @rows;
    is @newtx, 1, "new transaction found in the database";

    $transaction = {
        currency     => 'ETH',
        hash         => "withdrawal_test",
        to           => '36ob9DZcMYQkRHGFNJHjrEKP7N9RyTihHo',
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
    is $updated_transaction->{txn_fee}, 0.000247621;
};

sub _insert_withdrawal_transaction {
    my $transaction = shift;

    my $address = $transaction->{to};

    my $txn_db_id = $dbic->run(
        ping => sub {
            $_->selectrow_array(
                'SELECT payment.ctc_insert_new_withdraw(?, ?, ?, ?::JSONB, ?, ?, ?, ?)',
                undef,            $address, $transaction->{currency},
                $client->loginid, '{"":0}', $transaction->{amount},
                0,                1,        []);
        });

    $helper->process_withdrawal($txn_db_id, $address, $transaction->{amount});

    return $dbic->run(
        ping => sub {
            my $sth = $_->prepare('UPDATE payment.cryptocurrency SET blockchain_txn = ? , status = ? WHERE address = ? AND blockchain_txn IS NULL');
            $sth->execute($transaction->{hash}, 'PROCESSING', $address);
        });
}

sub _fetch_withdrawal_transaction {
    my ($blockchain_txn) = @_;
    return $dbic->run(
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
    my $id;
    lives_ok {
        ($id, $btc_address) = $helper->get_deposit_id_and_address;
    }
    'survived get_deposit_id_and_address';

    $transaction->{to} = $btc_address;

    my $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{error}, sprintf("Amount is zero for transaction: %s", $transaction->{hash}), "transaction with balance 0 but type eq receipt";

    $transaction->{type} = 'internal';

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{status}, 1, "transaction with balance 0 but type eq internal";

    my $rows = $dbic->run(
        fixup => sub {
            my $sth = $_->prepare(q{SELECT * FROM payment.ctc_find_deposit_pending_by_currency_code(?)});
            $sth->execute('BTC');
            return $sth->fetchall_arrayref({});
        });

    my @address_entries = grep { $_->{address} eq $btc_address } $rows->@*;

    is @address_entries, 1, "correct number of pending transactions for $btc_address";

    my ($address) =
        $dbic->run(
        fixup => sub { $_->selectrow_array('SELECT address from payment.ctc_find_new_deposit_address(?, ?)', undef, 'BTC', $client->loginid) });

    is $address, undef, 'no new address created when internal transactions was marked as pending';
};

subtest "New address threshold" => sub {

    my $client = create_client();
    $client->set_default_account('BTC');

    my $helper = BOM::CTC::Helper->new(client => $client);

    $mock_btc->mock(
        get_new_address => sub {
            return '4BLeXx1J9Tp3TBnQyHrhVxne9KqkAS9ABC',;
        });

    my ($id, $btc_address);

    lives_ok {
        ($id, $btc_address) = $helper->get_deposit_id_and_address;
    }
    'survived get_deposit_id_and_address';

    my $transaction = {
        currency     => 'BTC',
        hash         => '427d42cfa0717e8d4ce8b453de74cc84f3156861df07173876f6cfebdcbc099b',
        to           => $btc_address,
        type         => 'receive',
        fee          => 0.00002,
        fee_currency => 'BTC',
        amount       => 0.00001,
        block        => 10,
    };

    # mocking address again to make sure the new address is different
    # if the retain address is not called
    my $new_address = '5CLeXx1J9Tp3TBnQyHrhVxne9KqkAS9DEF';
    $mock_btc->mock(
        get_new_address => sub {
            return $new_address,;
        });

    $mock_subscription->mock(
        emit_new_address_call => sub {
            my ($client_loginid, $retain_address, $address) = @_;
            my $data = {
                loginid        => $client_loginid,
                retain_address => $retain_address,
                address        => $address,
            };
            BOM::Event::Actions::CryptoSubscription::new_crypto_address($data);
        });

    my $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, 1, "Correct status";

    my $res = $dbic->run(
        ping => sub {
            my $sth = $_->prepare('SELECT address, status from payment.cryptocurrency where address = ?');
            $sth->execute($btc_address)
                or die $sth->errstr;
            return $sth->fetchall_arrayref({});
        });

    is @$res, 2, "Correct number of same address record returned";
    my $address_with_new_exist = any { $_->{status} eq 'NEW' } @$res;
    is $address_with_new_exist, 1, "Address is retained";

    $transaction->{amount} = 10;
    $transaction->{hash}   = '427d42cfa0717e8d4ce8b453de74cc84f3156861df07173876f6cfebdcbc099c';

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response, 1, "Correct status";

    $res = $dbic->run(
        ping => sub {
            my $sth = $_->prepare('SELECT address, status from payment.cryptocurrency where address = ?');
            $sth->execute($btc_address)
                or die $sth->errstr;
            return $sth->fetchall_arrayref({});
        });

    is @$res, 2, "Correct number of same address record returned";

    $res = $dbic->run(
        ping => sub {
            my $sth = $_->prepare('SELECT address, status from payment.cryptocurrency where address = ?');
            $sth->execute($new_address)
                or die $sth->errstr;
            return $sth->fetchall_arrayref({});
        });

    is @$res, 1, "Correct response as address is not retained when the amount surpasses the threshold";

};

done_testing;
