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

my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $email    = 'get_available_accounts@nowhere.com';
my $password = 'Aer13';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($client_usd);
my $token_usd = BOM::Platform::Token::API->new->create_token($client_usd->loginid, 'test token');

my $c      = BOM::Test::RPC::QueueClient->new();
my $method = 'available_accounts';

my %categories = BOM::Config::AccountType::Registry->all_categories;

use constant Fiat_Results => ({
        account_type    => "doughflow",
        currency        => "AUD",
        landing_company => "svg",
    },
    {
        account_type    => "doughflow",
        currency        => "EUR",
        landing_company => "svg",
    },
    {
        account_type    => "doughflow",
        currency        => "GBP",
        landing_company => "svg",
    },
    {
        account_type    => "doughflow",
        currency        => "USD",
        landing_company => "svg",
    },
);

use constant Crypto_Results => ({
        account_type    => "crypto",
        currency        => "BTC",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "BUSD",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "DAI",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "ETH",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "EURS",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "IDK",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "LTC",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "PAX",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "TUSD",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "USB",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "USDC",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "USDK",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "UST",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "eUSDT",
        landing_company => "svg"
    },
    {
        account_type    => "crypto",
        currency        => "tUSDT",
        landing_company => "svg"
    },
);

subtest 'validation' => sub {

    my $params = {
        args => {
            $method => 1,
        }};

    $c->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'Correct error when called without token');
    $params->{token} = $token_usd;

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(residence => 'my');

    $c->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('RestrictedCountry', 'Correct error when residence country is blocked');
    $mock_client->unmock_all;
};

subtest 'wallets' => sub {
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    my $mock_client    = Test::MockModule->new('BOM::User::Client');
    $mock_countries->redefine(wallet_companies_for_country => ['svg']);

    my $params = {
        token => $token_usd,
        args  => {
            $method => 1,
            types   => ["wallet"]}};

    ## Test case handle no default currency set

    my $result = $c->call_ok($method, $params)->result;

    my @expected_result = (Fiat_Results, Crypto_Results);
    cmp_deeply $result->{wallets}, bag(@expected_result), "test to check if no default account was available for currency";

    $client_usd->set_default_account('USD');

    $result = $c->call_ok($method, $params)->result;

    cmp_deeply $result->{wallets}, bag(@expected_result), "expected result contains all possible values";

    my $client_wallet_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CRW',
    });
    $user->add_client($client_wallet_usd);
    $result = $c->call_ok($method, $params)->result;
    cmp_deeply $result->{wallets}, bag(@expected_result), "added new broker code CRW but no default account was available for currency";

    $client_wallet_usd->set_default_account('USD');
    $result = $c->call_ok($method, $params)->result;

    @expected_result = (Crypto_Results);
    cmp_deeply $result->{wallets}, bag(@expected_result), "no fiat wallet will be availabe";

    my $client_wallet_BTC = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code  => 'CRW',
        account_type => 'crypto'
    });

    $user->add_client($client_wallet_BTC);

    $client_wallet_BTC->set_default_account('BTC');
    $result = $c->call_ok($method, $params)->result;

    @expected_result = grep { $_->{currency} ne 'BTC' } Crypto_Results;
    cmp_deeply $result->{wallets}, bag(@expected_result), "only BTC wallet will not be available";

    my $client_usd_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CRW',
    });

    # New account with 1 BTC account only should have all the doughlow
    $email = 'get_available_account_1@nowhere.com';

    $client_usd_1->set_default_account('USD');
    my $user_1 = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user_1->add_client($client_usd_1);
    my $token_usd_1 = BOM::Platform::Token::API->new->create_token($client_usd_1->loginid, 'test token');
    $params = {
        token => $token_usd_1,
        args  => {
            $method => 1,
            types   => ["wallet"]}};
    $result = $c->call_ok($method, $params)->result;

    @expected_result = (Crypto_Results);
    cmp_deeply $result->{wallets}, bag(@expected_result), "only crypto wallets will be available";

};

done_testing();
