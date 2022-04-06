#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Exception;

use Net::Async::Blockchain::Transaction;
use BOM::Event::Actions::CryptoSubscription;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::CryptoTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client );
use BOM::Test;
use BOM::CTC::Helper;
use BOM::CTC::Database;
use BOM::CTC::Constants qw(:transaction :crypto_config);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_events_redis);
use BOM::Platform::Event::Emitter;
use IO::Async::Loop;
use BOM::Event::Services;
use List::Util qw(all any);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);
use BOM::Test::Helper::CTC;
use Future::AsyncAwait;
use Format::Util::Numbers qw/financialrounding/;

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
    my $from_address       = $currency->get_new_address();

    my $transaction = {
        currency => $currency_code,
        hash     => $transaction_hash1,
        to       => '36ob9DZcMYQkRHGFNJHjrEKP7N9RyTihHW',
        from     => $from_address,
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

    $currency_code = 'BTC';
    $transaction->{to} = $btc_address;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{error},
        sprintf("Invalid currency, expecting: %s, received: %s, for transaction: %s", $currency_code, $transaction->{currency}, $transaction->{hash}),
        "Invalid currency";

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
        ok $response, "response ok from the database";
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
};

subtest "internal_transactions" => sub {

    my $client = create_client();
    $client->set_default_account('BTC');
    my $helper = BOM::CTC::Helper->new(client => $client);

    my $currency     = BOM::CTC::Currency->new(currency_code => 'BTC');
    my $from_address = $currency->get_new_address();

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
        from     => $from_address,
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

    my $currency     = BOM::CTC::Currency->new(currency_code => 'BTC');
    my $from_address = $currency->get_new_address();

    my $transaction = {
        currency     => 'BTC',
        hash         => '427d42cfa0717e8d4ce8b453de74cc84f3156861df07173876f6cfebdcbc099b',
        to           => $btc_address,
        from         => $from_address,
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
    is $response->{status}, 1, "Correct status";

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
    is $response->{status}, 1, "Correct status";

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

subtest "new_crypto_address" => sub {
    my $first_address = 'tb1q2nx3ey8a0659x5k0reuctvqs3xfrm4wg2awh43';
    $mock_btc->mock(
        get_new_address => sub {
            return $first_address;
        });

    my $currency = BOM::CTC::Currency->new(currency_code => 'BTC');

    my $client = create_client();
    $client->set_default_account($currency->currency_code);

    my $helper   = BOM::CTC::Helper->new(client => $client);
    my $response = BOM::Event::Actions::CryptoSubscription::new_crypto_address({loginid => $client->loginid});
    ok $response, "address generation ok";

    my $address = $response;

    my $threshold = BOM::Config::CurrencyConfig::get_crypto_new_address_threshold($currency->currency_code);
    # This is a very low amount just to check if the address will not be new after
    # the check on the first transaction
    my $amount = 0.00001;

    my $checked_threshold = BOM::Event::Actions::CryptoSubscription::requires_address_retention($currency->currency_code, $address);
    is $checked_threshold, 1, "correct response for keep the address retained";

    my $second_address = 'tb1qr0y0djpk4tq7tek97tnjs5f334z267qzpmfldp';
    $mock_btc->mock(
        get_new_address => sub {
            return $second_address;
        });

    $response = BOM::Event::Actions::CryptoSubscription::new_crypto_address({loginid => $client->loginid});
    is $address, $response, "same address returned when the address is new even if the retain address is not passed";

    $response = BOM::Event::Actions::CryptoSubscription::new_crypto_address({
        loginid        => $client->loginid,
        retain_address => 1,
        address        => $address
    });
    is $address, $response, "same address returned when the retain_address is passed";

    my $transaction = {
        currency     => $currency->currency_code,
        hash         => '427d42cfa0717e8d4ce8b453de74cc84f3156861df07173876f6cfebdcbc099a',
        to           => $address,
        type         => 'receive',
        fee          => 0.00001,
        fee_currency => $currency->currency_code,
        amount       => $amount,
        block        => 10,
    };

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{status}, 1, "Update the transaction status to pending";

    $amount = $threshold;

    $checked_threshold = BOM::Event::Actions::CryptoSubscription::requires_address_retention($currency->currency_code, $address);
    is $checked_threshold, 1, "correct response for keep the address retained even with 1 deposit";

    $transaction->{amount} = 0.1;
    $transaction->{hash}   = "aaa";
    $transaction->{from}   = $currency->account_config->{account}->{address};

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{status}, 0, "the from address is equals to the main address";
    is $response->{error}, sprintf("`from` address is main address for transaction: %s", $transaction->{hash}),
        "correct error message for froma => main address";

    $transaction->{from} = undef;

    $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);
    is $response->{status}, 1, "Update the transaction status to pending";

    $checked_threshold = BOM::Event::Actions::CryptoSubscription::requires_address_retention($currency->currency_code, $address);
    is $checked_threshold, 0, "correct response for address retention not needed";

    $response = BOM::Event::Actions::CryptoSubscription::new_crypto_address({loginid => $client->loginid});
    is $second_address, $response, "different address returned when the address is not new";

    my $res = $dbic->run(
        ping => sub {
            my $sth = $_->prepare('SELECT address from payment.cryptocurrency where client_loginid = ? and status = ?');
            $sth->execute($client->loginid, 'NEW')
                or die $sth->errstr;
            return $sth->fetchall_arrayref({});
        });

    is @$res, 1, "Correct response as address is not retained when the amount surpasses the threshold";
    is $res->[0]->{address}, $second_address, "correct new address";
};

subtest "Skip ETH fee transaction" => sub {
    my $client = create_client();
    $client->set_default_account('ETH');
    my $helper = BOM::CTC::Helper->new(client => $client);

    my $mock_eth = Test::MockModule->new('BOM::CTC::Currency::ETH');
    $mock_eth->mock(
        get_new_address => sub {
            return '0x63D264afFf99944ba1523f88DDba08B611350a8D',;
        });

    my ($id, $eth_address) = $helper->get_deposit_id_and_address;

    my $currency     = BOM::CTC::Currency->new(currency_code => 'ETH');
    my $main_address = $currency->account_config->{account}->{address};

    my $transaction = {
        'type'         => 'internal',
        'block'        => 118333,
        'amount'       => '0.00093976',
        'hash'         => '0x69faf1857fb8cca53e84bc7a0cd11d1c1ffee7dbb3e2372e84f15b5792cbcafa',
        'currency'     => 'ETH',
        'from'         => $main_address,
        'fee_currency' => 'ETH',
        'property_id'  => undef,
        'to'           => $eth_address,
        'fee'          => '2310000000000000'
    };

    my $response = BOM::Event::Actions::CryptoSubscription::set_pending_transaction($transaction);

    my $res = $dbic->run(
        ping => sub {
            my $sth = $_->prepare('SELECT * from payment.cryptocurrency where address = ?');
            $sth->execute($eth_address)
                or die $sth->errstr;
            return $sth->fetchall_arrayref({});
        });

    is $res->[0]->{status}, 'NEW', "correct transaction status";
};

subtest "ERC20 deposit swept on subscription" => sub {
    # mock this subroutine so that get_deposit_id_and_address call does not invoke node in bom-cryptocurrency
    my $mock_eth = Test::MockModule->new('BOM::CTC::Currency::ETH');
    $mock_eth->mock(
        get_new_address => sub {
            return '0x63D264afFf99944ba1523f88DDDa08B611350a8D',;
        });

    foreach my $currency_code ('USDC', 'eUSDT') {
        my $amount           = 1;
        my $transaction_hash = "dummy_hash";

        my $client = create_client();
        $client->set_default_account($currency_code);
        $client->save();
        my $helper    = BOM::CTC::Helper->new(client => $client);
        my $db_helper = BOM::CTC::Database->new();

        #deposit amount to a new address
        my ($deposit_id, $address) = $helper->get_deposit_id_and_address();
        BOM::Test::Helper::CTC::set_pending($address, $currency_code, $amount, $transaction_hash);
        $db_helper->set_deposit_confirmed($deposit_id, $deposit_id, $amount, $transaction_hash);

        my @pending_sweep_deposits = $db_helper->get_addresses_pending_sweep($currency_code)->@*;
        is scalar(@pending_sweep_deposits), 1, "correct no of pending sweep deposits after deposit";

        # Check for case when we first send ETH to ERC20 address as fee for the actual transaction. deposit should not be swept now
        BOM::Event::Actions::CryptoSubscription::_set_deposit_swept({
            type         => TRANSACTION_TYPE_INTERNAL,
            from         => $address,
            currency     => 'ETH',
            fee_currency => 'ETH'
        });

        @pending_sweep_deposits = $db_helper->get_addresses_pending_sweep($currency_code)->@*;
        is scalar(@pending_sweep_deposits), 1, "correct no of pending sweep deposits after eth sent to ERC20 address";

        # Check for case when we receive actual transaction in subscription.
        BOM::Event::Actions::CryptoSubscription::_set_deposit_swept({
            type         => TRANSACTION_TYPE_INTERNAL,
            from         => $address,
            currency     => $currency_code,
            fee_currency => 'ETH'
        });

        @pending_sweep_deposits = $db_helper->get_addresses_pending_sweep($currency_code)->@*;
        is scalar(@pending_sweep_deposits), 0, "correct no of pending sweep deposits after subscription receives an internal sweep transaction";
    }

    $mock_eth->unmock_all();
};

subtest "update_crypto_config: event emitted from subscription" => sub {
    my $redis_write = BOM::Config::Redis::redis_replicated_write();
    my $redis_read  = BOM::Config::Redis::redis_replicated_read();

    $redis_write->del("cryptocurrency::crypto_config::BTC");

    #event should not proceed and response should be zero when event is called without any currency passed in param
    my $event_response = BOM::Event::Actions::CryptoSubscription::update_crypto_config();

    is $event_response, 0, "correct event response when no currency passed";

    #event should not proceed and response should be zero when event is called with non crypto currency
    $event_response = BOM::Event::Actions::CryptoSubscription::update_crypto_config('USD');

    is $event_response, 0, "correct event response when non crypto currency is passed";

    my $mock_btc_currency = Test::MockModule->new('BOM::CTC::Currency::BTC');

    $mock_btc_currency->mock(
        get_minimum_withdrawal => sub {
            return 0.123;
        });

    my $btc_min_withdrawal = $redis_read->get(CRYPTO_CONFIG_REDIS_KEY . "BTC");

    #before event btc min withdrawal shouldn't be found on redis
    is $btc_min_withdrawal, undef, "btc min withdrawal should be undef";

    # this event should set btc config in redis
    BOM::Event::Actions::CryptoSubscription::update_crypto_config("BTC");

    $btc_min_withdrawal = $redis_read->get(CRYPTO_CONFIG_REDIS_KEY . "BTC");

    is $btc_min_withdrawal, (0 + financialrounding('amount', "BTC", 0.123)), "correct btc min withdrawal";
    $redis_write->del("cryptocurrency::crypto_config::BTC");

    $mock_btc_currency->unmock_all();
};

done_testing;
