use strict;
use warnings;
use utf8;

use Test::More;
use Test::Deep;
use Test::MockModule;

use BOM::Test::Helper::Token;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::BOM::RPC::QueueClient;
use BOM::Platform::Token::API;
use BOM::Config::AccountType;
use BOM::Config::AccountType::Registry;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

my @all_crypto_currencies = qw(ETH eUSDT tUSDT BTC LTC UST USDC);
my @all_fiat_currencies   = qw(EUR AUD USD GBP);
my @malta_fiat_currencies = qw(EUR USD GBP);
my @all_currencies        = (@all_crypto_currencies, @all_fiat_currencies);

my @linkable_wallet_svg     = qw(doughflow crypto p2p paymentagent_client);
my @linkable_wallet_malta   = qw(doughflow);
my @linkable_wallet_virtual = qw(virtual);

my $c      = BOM::Test::RPC::QueueClient->new();
my $method = 'get_account_types';

my %categories = BOM::Config::AccountType::Registry->all_categories;

subtest 'validation' => sub {

    my $params = {args => {$method => 1}};

    $c->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'Correct error when called without token');
    $params->{token} = $token;

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(residence => 'my');

    $c->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('RestrictedCountry', 'Correct error when residence country is blocked');
    $mock_client->unmock_all;
};

subtest 'account categories' => sub {

    my $mock_countries = Test::MockModule->new('Brands::Countries');
    my $mock_client    = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(residence => 'za');

    my %account_types = (
        svg => {
            trading => [qw/standard binary mt5 dxtrade derivez/],
            wallet  => [qw/doughflow crypto p2p paymentagent paymentagent_client/],
        },
        maltainvest => {
            trading => [qw/standard binary mt5/],
            wallet  => [qw/doughflow/],
        },
        virtual => {
            trading => [qw/standard binary mt5 dxtrade derivez/],
            wallet  => [qw/virtual/],
        });

    foreach my $company (sort keys %account_types) {
        $mock_countries->redefine(wallet_companies_for_country => [$company]);

        my $params = {
            token => $token,
            args  => {
                $method => 1,
                company => $company
            }};
        my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;

        my $account_type = $account_types{$company};

        for my $category (sort keys %{$account_type}) {
            # Check if number offerings matches the number expected to offer
            my $number_expected = scalar @{$account_type->{$category}};
            my $number_got      = keys %{$result->{$category}};
            is $number_got, $number_expected, "[$company] number offerings for $category correct.";

            for my $type ($account_type->{$category}->@*) {
                my $type_data    = $result->{$category}->{$type};
                my $company_name = $company ? $company : 'default';
                ok $type_data, "[$company_name] - Account type $category-$type exists in the response";
                is ref $type_data, 'HASH', "[$company_name] - Account type info is a hash-ref";
            }
        }
    }
};

subtest 'wallet currencies' => sub {
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    my $mock_client    = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(residence => 'za');

    my %wallets_currencies = (
        maltainvest => {
            doughflow => bag(@malta_fiat_currencies),
        },
        svg => {
            doughflow           => bag(@all_fiat_currencies),
            crypto              => bag(@all_crypto_currencies),
            p2p                 => bag('USD'),
            paymentagent        => bag(@all_currencies),
            paymentagent_client => bag(@all_currencies),
        },
        virtual => {
            virtual => ['USD'],
        });

    foreach my $company (sort keys %wallets_currencies) {
        $mock_countries->redefine(wallet_companies_for_country => [$company]);
        my $params = {
            token => $token,
            args  => {
                $method => 1,
                company => $company
            }};

        my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;

        my $wallets = $wallets_currencies{$company};
        foreach my $wallet (keys %{$wallets}) {

            cmp_deeply $result->{wallet}->{$wallet}->{currencies}, $wallets->{$wallet}, "$company - $wallet currencies are correct";
        }
    }
};

subtest 'trading account attributes' => sub {
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    my $mock_client    = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(residence => 'za');

    my %trading_accounts = (
        svg => {
            mt5 => {
                allowed_wallet_currencies      => bag(@all_fiat_currencies),
                linkable_to_different_currency => 1,
                linkable_wallet_types          => bag('doughflow', 'p2p', 'paymentagent_client'),
            },
            binary => {
                allowed_wallet_currencies      => bag(@all_currencies),
                linkable_to_different_currency => 0,
                linkable_wallet_types          => bag(@linkable_wallet_svg),
            },
            standard => {
                allowed_wallet_currencies      => bag(@all_currencies),
                linkable_to_different_currency => 0,
                linkable_wallet_types          => bag(@linkable_wallet_svg),
            },
            dxtrade => {
                allowed_wallet_currencies      => bag(@all_fiat_currencies),
                linkable_to_different_currency => 1,
                linkable_wallet_types          => bag('doughflow', 'p2p', 'paymentagent_client'),
            },
        },
        maltainvest => {
            mt5 => {
                allowed_wallet_currencies      => bag(@malta_fiat_currencies),
                linkable_to_different_currency => 1,
                linkable_wallet_types          => ['doughflow'],
            },
            binary => {
                allowed_wallet_currencies      => bag(@malta_fiat_currencies),
                linkable_to_different_currency => 0,
                linkable_wallet_types          => bag(@linkable_wallet_malta),
            },
            standard => {
                allowed_wallet_currencies      => bag(@malta_fiat_currencies),
                linkable_to_different_currency => 0,
                linkable_wallet_types          => bag(@linkable_wallet_malta),
            },

        },
        virtual => {
            mt5 => {
                allowed_wallet_currencies      => ['USD'],
                linkable_to_different_currency => 1,
                linkable_wallet_types          => bag(@linkable_wallet_virtual),
            },
            binary => {
                allowed_wallet_currencies      => ['USD'],
                linkable_to_different_currency => 0,
                linkable_wallet_types          => bag(@linkable_wallet_virtual),
            },
            standard => {
                allowed_wallet_currencies      => ['USD'],
                linkable_to_different_currency => 0,
                linkable_wallet_types          => bag(@linkable_wallet_virtual),
            },
            dxtrade => {
                allowed_wallet_currencies      => ['USD'],
                linkable_to_different_currency => 1,
                linkable_wallet_types          => bag(@linkable_wallet_virtual),
            }});

    foreach my $company (keys %trading_accounts) {
        $mock_countries->redefine(wallet_companies_for_country => [$company]);
        my $params = {
            token => $token,
            args  => {
                $method => 1,
                company => $company
            }};
        my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;

        my $accounts = $trading_accounts{$company};
        foreach my $account_name (keys %{$accounts}) {
            my $expected_result = $accounts->{$account_name};

            cmp_deeply $result->{trading}->{$account_name}, $expected_result, "[$company] $account_name attributes are correct";
        }
    }
};

done_testing();
