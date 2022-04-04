#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( create_client top_up);
use BOM::Platform::CryptoCashier::Iframe::Controller;
use BOM::Config::Runtime;
use BOM::User::Client;
use BOM::Test::Helper::ExchangeRates qw(populate_exchange_rates);

my $mock_crypto_api    = Test::MockModule->new('BOM::Platform::CryptoCashier::API');
my $mock_crypto_config = Test::MockModule->new('BOM::Platform::CryptoCashier::Config');

$mock_crypto_api->mock(
    deposit => sub {
        return {
            action  => 'deposit',
            deposit => {
                address => "1PY4YtttvicMkwae5sQYsb5MMg32jNNvGJ",
            },
        };
    },
    transactions => sub {
        return {
            crypto => [],
        };
    },
);

$mock_crypto_config->mock(
    crypto_config => sub {
        return {
            currencies_config => {
                BTC => {
                    minimum_withdrawal => 0.1,
                },
            },
        };
    },
);

populate_exchange_rates();

$ENV{CTC_CONFIG} = "t/BOM/Platform/CryptoCashier/resources/mojo.conf";

my $mock_client = Test::MockModule->new('BOM::User::Client');
$mock_client->mock(
    missing_requirements => sub {
        return ();
    });

my $t = Test::Mojo->new('BOM::Platform::CryptoCashier::Iframe');
$t->ua->max_redirects(1);

my $handshake = "/btc/handshake?token=%s&loginid=%s&action=%s&l=%s&brand=binary&currency=BTC";

subtest "handshake" => sub {
    my $user = BOM::User->create(
        email    => 'test@binary.com',
        password => 'abcd'
    );

    my $client = create_client();
    $client->set_default_account('BTC');
    $client->save();

    $user->add_client($client);
    $t->app->sessions->secure(0);

    $t->app->routes->find('')->remove();
    $t->app->routes->find('')->remove();
    $t->app->routes->get('/cryptocurrency/btc/deposit')->to('Controller#deposit');
    $t->app->routes->get('/cryptocurrency/btc/withdrawal')->to('Controller#withdraw');

    BOM::Config::Runtime->instance->app_config->cgi->allowed_languages([qw(EN ID RU ES FR PT DE ZH_CN JA PL VI ZH_TW IT TH)]);

    my $token = BOM::Platform::CryptoCashier::Iframe::Controller::_get_handoff_token_key($client->loginid);

    $t->get_ok(sprintf($handshake, $token, $client->loginid, 'deposit', 'EN'))->status_is(200)->content_like(qr/Send only Bitcoin/);

    $token = BOM::Platform::CryptoCashier::Iframe::Controller::_get_handoff_token_key($client->loginid);
    TODO: {
        local $TODO = 'These tests are in a TODO because we do not have the translations yet.' if 1;
        $t->get_ok(sprintf($handshake, $token, $client->loginid, 'deposit', 'ID'))->status_is(200)->content_like(qr/Hanya Bitcoin/);

        $token = BOM::Platform::CryptoCashier::Iframe::Controller::_get_handoff_token_key($client->loginid);

        $t->get_ok(sprintf($handshake, $token, $client->loginid, 'deposit', 'IT'))->status_is(200)->content_like(qr/Invia solo Bitcoin/);
    }
    $token = BOM::Platform::CryptoCashier::Iframe::Controller::_get_handoff_token_key($client->loginid);

    $t->get_ok(sprintf($handshake, $token, $client->loginid, 'withdrawal', 'EN'))->status_is(200)
        ->content_like(qr/Do not withdraw directly to a crowdfund/);

    $token = BOM::Platform::CryptoCashier::Iframe::Controller::_get_handoff_token_key($client->loginid);

    $t->get_ok(sprintf($handshake, $token, $client->loginid, 'withdrawal', 'ID'))->status_is(200)
        ->content_like(qr/Jangan menarik langsung ke crowdfund/);

    $token = BOM::Platform::CryptoCashier::Iframe::Controller::_get_handoff_token_key($client->loginid);

    $t->get_ok(sprintf($handshake, $token, $client->loginid, 'withdrawal', 'IT'))->status_is(200)
        ->content_like(qr/Non effettuare operazioni direttamente verso un indirizzo di crowdfunding/);
};

$mock_crypto_api->unmock_all();
$mock_crypto_config->unmock_all();

done_testing;

