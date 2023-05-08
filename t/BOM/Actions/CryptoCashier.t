#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;

use BOM::Event::Actions::CryptoCashier;
use JSON::MaybeUTF8 qw(decode_json_utf8);

my $mocked_crypto_cashier = Test::MockModule->new('BOM::Event::Actions::CryptoCashier');
my $mocked_redis          = Test::MockModule->new('RedisDB');
my $mocked_event_emitter  = Test::MockModule->new('BOM::Platform::Event::Emitter');

subtest 'crypto_cashier_transaction_updated' => sub {
    subtest "Exists handler for the recevied event - Withdrawal Sent" => sub {
        my $txn_info = {
            id                 => 1,
            address_hash       => 'address_hash',
            address_url        => 'address_url',
            amount             => 1,
            currency_code      => 'ETH',
            is_valid_to_cancel => 0,
            status_code        => 'SENT',
            status_message     => 'message',
            submit_date        => '162',
            transaction_hash   => 'transaction_hash',
            transaction_type   => 'withdrawal',
            transaction_url    => 'transaction_url',
            metadata           => {
                loginid => 'loginid',
            },
        };

        my $txn_info_cp           = {%$txn_info};
        my $expected_txn_metadata = delete $txn_info_cp->{metadata};
        my $expected_txn_info     = $txn_info_cp;

        my ($p_txn_info, $p_txn_metadata);
        BOM::Event::Actions::CryptoCashier::TRANSACTION_HANDLERS->{'withdrawal'}{'SENT'} = sub {
            ($p_txn_info, $p_txn_metadata) = @_;
            return;
        };

        my $expected_redis_key     = 'CASHIER::PAYMENTS::' . $expected_txn_metadata->{loginid};
        my $expected_redis_message = {
            crypto         => [$expected_txn_info],
            client_loginid => $expected_txn_metadata->{loginid},
        };

        my ($redis_key, $message);
        $mocked_redis->mock(
            publish => sub {
                (undef, $redis_key, $message) = @_;
                $message = decode_json_utf8($message);
                return;
            },
        );

        #case when send_client_email is not defined
        BOM::Event::Actions::CryptoCashier::crypto_cashier_transaction_updated($txn_info);
        is_deeply $p_txn_info,     $expected_txn_info,     'Correct txn_info parameter';
        is_deeply $p_txn_metadata, $expected_txn_metadata, 'Correct txn_metadata parameter';
        is $redis_key, $expected_redis_key, 'Correct Redis channel key';
        is_deeply $message, $expected_redis_message, 'Correct published message';

        #case when send_client_email is set as 0
        my $send_client_email = 0;
        $txn_info->{metadata} = {
            loginid           => 'loginid',
            send_client_email => $send_client_email,
        };
        $p_txn_info = undef;
        BOM::Event::Actions::CryptoCashier::crypto_cashier_transaction_updated($txn_info);
        is_deeply $message,    $expected_redis_message, 'Correct published message';
        is_deeply $p_txn_info, undef,                   'Correct response';            #because handler/s not being called as send_client_email = 0

        $mocked_redis->unmock_all;
    };
};

subtest 'withdrawal_handler' => sub {

    my $txn_info = {
        id                 => 1,
        address_hash       => 'address_hash',
        address_url        => 'address_url',
        amount             => 1,
        is_valid_to_cancel => 0,
        status_code        => 'SENT',
        status_message     => 'message',
        submit_date        => '162',
        transaction_hash   => 'transaction_hash',
        transaction_type   => 'withdrawal',
        transaction_url    => 'transaction_url',
    };

    my $txn_metadata = {
        loginid       => 'loginid',
        currency_code => 'ETH',
    };

    my $expected_events = [{
            payment_withdrawal => {
                loginid  => $txn_metadata->{loginid},
                amount   => $txn_info->{amount},
                currency => $txn_metadata->{currency_code},
            }
        },
        {
            crypto_withdrawal_email => {
                amount             => $txn_info->{amount},
                loginid            => $txn_metadata->{loginid},
                currency           => $txn_metadata->{currency_code},
                transaction_hash   => $txn_info->{transaction_hash},
                transaction_url    => $txn_info->{transaction_url},
                reference_no       => $txn_info->{id},
                transaction_status => $txn_info->{status_code},
            }
        },
    ];

    my @events;
    $mocked_event_emitter->mock(
        emit => sub {
            my ($event_name, $event_data) = @_;
            push @events, {$event_name => $event_data};
            return;
        },
    );

    BOM::Event::Actions::CryptoCashier::withdrawal_handler($txn_info, $txn_metadata);
    is_deeply \@events, $expected_events, 'Correct events';

    $mocked_event_emitter->unmock_all;
};

subtest 'deposit_pending_handler' => sub {

    my $txn_info = {
        id                 => 1,
        address_hash       => 'address_hash',
        address_url        => 'address_url',
        amount             => 1,
        is_valid_to_cancel => 0,
        status_code        => 'PENDING',
        status_message     => 'message',
        submit_date        => '162',
        transaction_hash   => 'transaction_hash',
        transaction_type   => 'deposit',
        transaction_url    => 'transaction_url',
    };

    my $txn_metadata = {
        loginid       => 'loginid',
        currency_code => 'ETH',
    };

    my $expected_events = [{
            crypto_deposit_email => {
                loginid            => $txn_metadata->{loginid},
                amount             => $txn_info->{amount},
                currency           => $txn_metadata->{currency_code},
                transaction_hash   => $txn_info->{transaction_hash},
                transaction_status => $txn_info->{status_code},
                transaction_url    => $txn_info->{transaction_url},
            }
        },
    ];

    my @events;
    $mocked_event_emitter->mock(
        emit => sub {
            my ($event_name, $event_data) = @_;
            push @events, {$event_name => $event_data};
            return;
        },
    );

    BOM::Event::Actions::CryptoCashier::deposit_handler($txn_info, $txn_metadata);
    is_deeply \@events, $expected_events, 'Correct events';

    $mocked_event_emitter->unmock_all;
};

subtest 'deposit_confirmed_handler' => sub {

    my $txn_info = {
        id                 => 1,
        address_hash       => 'address_hash',
        address_url        => 'address_url',
        amount             => 1,
        is_valid_to_cancel => 0,
        status_code        => 'CONFIRMED',
        status_message     => 'message',
        submit_date        => '162',
        transaction_hash   => 'transaction_hash',
        transaction_type   => 'deposit',
        transaction_url    => 'transaction_url',
    };

    my $txn_metadata = {
        login_id      => 'login_id',
        currency_code => 'ETH',
    };

    my $expected_events = [{
            crypto_deposit_email => {
                loginid            => $txn_metadata->{loginid},
                amount             => $txn_info->{amount},
                currency           => $txn_metadata->{currency_code},
                transaction_hash   => $txn_info->{transaction_hash},
                transaction_status => $txn_info->{status_code},
                transaction_url    => $txn_info->{transaction_url},
            }
        },
    ];

    my @events;
    $mocked_event_emitter->mock(
        emit => sub {
            my ($event_name, $event_data) = @_;
            push @events, {$event_name => $event_data};
            return;
        },
    );

    BOM::Event::Actions::CryptoCashier::deposit_handler($txn_info, $txn_metadata);
    is_deeply \@events, $expected_events, 'Correct events';

    $mocked_event_emitter->unmock_all;
};

done_testing;
