#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Exception;

use Format::Util::Numbers qw(financialrounding);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(create_client top_up);
use BOM::Test::Helper::ExchangeRates           qw(populate_exchange_rates);
use BOM::Test::Helper::Utility                 qw(random_email_address);

use BOM::Platform::CryptoCashier::Payment::API::Controller;
use BOM::Platform::CryptoCashier::Payment::Error qw(create_error);

my $currency = 'BTC';
populate_exchange_rates({$currency => 100});

my $user = BOM::User->create(
    email    => random_email_address,
    password => 'test',
);
my $crypto_client = create_client();
$crypto_client->set_default_account($currency);
$user->add_client($crypto_client);
my $crypto_loginid = $crypto_client->loginid;

my $mocked_mojolicious = Test::MockModule->new('Mojolicious::Controller');

$mocked_mojolicious->mock(render => sub { my (undef, %response) = @_; return +{%response}; });

subtest "init_payment_validation" => sub {
    my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new();

    subtest "No client found" => sub {
        my $expected_error = create_error('ClientNotFound', message_params => 'CR123');
        is_deeply $controller->init_payment_validation('BTC', 'CR123', 1), $expected_error, 'Correct Error ClientNotFound';
    };

    subtest "Invalid currency" => sub {
        my $expected_error = create_error('InvalidCurrency', message_params => 'USD');
        is_deeply $controller->init_payment_validation('USD', $crypto_loginid, 1), $expected_error, 'Correct Error InvalidCurrency';
    };

    subtest "wrong currency" => sub {
        my $expected_error = create_error('CurrencyNotMatch', message_params => 'ETH');
        is_deeply $controller->init_payment_validation('ETH', $crypto_loginid, 1), $expected_error, 'Correct Error CurrencyNotMatch';
    };

    subtest "zero amount" => sub {
        my $expected_error = create_error('ZeroPaymentAmount');
        is_deeply $controller->init_payment_validation('BTC', $crypto_loginid, 0), $expected_error, 'Correct Error ZeroPaymentAmount';
    };

    subtest "No error" => sub {
        is $controller->init_payment_validation('BTC', $crypto_loginid, 1), undef, 'Correct response when the currency and amount are corrects';
    };
};

subtest "get_payment_id_from_clientdb" => sub {
    my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new();
    $controller->{client} = $crypto_client;

    subtest "deposit" => sub {
        is $controller->get_payment_id_from_clientdb($crypto_loginid, 55, 'deposit'), undef, 'No despoit payment found';

        my %payment_args = (
            currency         => 'BTC',
            amount           => 1,
            remark           => 'address_hash',
            crypto_id        => 55,
            transaction_hash => 'tx_hash',
            address          => 'address_hash',
        );

        my $txn = $crypto_client->payment_ctc(%payment_args);
        is $controller->get_payment_id_from_clientdb($crypto_loginid, 55, 'deposit'), $txn->{payment_id}, 'deposit payment found';
    };

    subtest "withdrawal" => sub {
        is $controller->get_payment_id_from_clientdb($crypto_loginid, 56, 'withdrawal'), undef, 'No withdrawal payment found';

        my %payment_args = (
            currency         => 'BTC',
            amount           => -1,
            remark           => 'address_hash',
            crypto_id        => 56,
            transaction_hash => 'tx_hash',
            address          => 'address_hash',
        );

        my $txn = $crypto_client->payment_ctc(%payment_args);
        is $controller->get_payment_id_from_clientdb($crypto_loginid, 56, 'withdrawal'), $txn->{payment_id}, 'withdrawal payment found';
    };
};

subtest "invalid_request" => sub {
    my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
    is_deeply $controller->invalid_request,
        {
        text   => 'Invalid request.',
        status => 404
        },
        'Correct response';
};

subtest "render_response" => sub {
    my $controller = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
    is_deeply $controller->render_response('test'), {json => 'test'}, 'Correct response';
};

subtest "render_error" => sub {
    my $controller        = BOM::Platform::CryptoCashier::Payment::API::Controller->new;
    my $expected_error    = create_error('FailedDebit', message_params => '1');
    my $expected_response = {
        json => {error => $expected_error},
    };
    is_deeply $controller->render_error('FailedDebit', message_params => '1'), $expected_response, 'Correct response';
};

$mocked_mojolicious->unmock_all();

done_testing;
