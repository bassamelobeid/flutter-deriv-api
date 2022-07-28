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

my @all_currencies = qw(EUR EURS PAX ETH IDK AUD eUSDT tUSDT BTC USDK LTC USB UST USDC TUSD USD GBP DAI BUSD);

my $c      = BOM::Test::RPC::QueueClient->new();
my $method = 'get_account_types';

my %categories = BOM::Config::AccountType::Registry->all_categories;

subtest 'validation' => sub {

    my $params = {args => {$method => 1}};

    $c->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidToken', 'Correct error when called without token');
    $params->{token} = $token;

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(residence => 'xyz');
    $c->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('PermissionDenied', 'Correct error when residence country is blocked');
    $mock_client->unmock_all;
};

subtest 'sample cases' => sub {
    my $params = {
        token => $token,
        args  => {$method => 1}};
    my $result        = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    my %account_types = (
        trading => [qw/demo real/],
        wallet  => [qw/demo fiat crypto p2p affiliate paymentagent paymentagent_client/],
        binary  => [qw/demo real/],
        mt5     => [qw/demo financial gaming/],
        derivx  => [qw/demo real/],
    );
    for my $category (keys %account_types) {
        for my $type ($account_types{$category}->@*) {
            my $type_data = $result->{$category}->{$type};
            ok $type_data, "Account type $category-$type exists in the response";
            is ref $type_data, 'HASH', 'Account type info is a hash-ref';
        }
    }

    # verify a few specific cases
    cmp_deeply $result->{wallet}->{fiat},
        {
        'services'             => bag('link_to_accounts', 'fiat_cashier'),
        'is_demo'              => 0,
        'currencies_available' => bag('EUR', 'AUD', 'USD', 'GBP'),
        },
        'Wallet-fiat attrbutes are correct';

    cmp_deeply $result->{binary}->{real},
        {
        'is_demo'  => 0,
        'services' => bag(
            'transfer_without_link', 'trade',                 'fiat_cashier', 'crypto_cashier',
            'paymentagent_transfer', 'paymentagent_withdraw', 'p2p',          'get_commissions'
        ),
        'currencies_available'           => bag(@all_currencies),
        'linkable_wallet_types'          => bag(qw/fiat crypto p2p paymentagent paymentagent_client affiliate/),
        'linkable_wallet_currencies'     => bag(@all_currencies),
        'linkable_to_different_currency' => 0,
        },
        'binary-real attributes are correct';

    cmp_deeply $result->{mt5}->{financial},
        {
        'services'                       => [],
        'is_demo'                        => 0,
        'currencies_available'           => bag('USD', 'EUR'),
        'linkable_to_different_currency' => 1,
        'linkable_wallet_types'          => bag(qw/fiat crypto p2p paymentagent paymentagent_client affiliate/),
        'linkable_wallet_currencies'     => bag(@all_currencies),
        },
        'mt5-financial attributes are correct';
};

subtest 'currency limitations' => sub {
    my $account_type = BOM::Config::AccountType->new(
        name     => 'test',
        category => $categories{trading},
        groups   => []);

    my $mock_category = Test::MockModule->new('BOM::Config::AccountType::Category');
    $mock_category->redefine(account_types => sub { return {test => $account_type} });
    my $expected_trading = {
        'services'                       => [],
        'is_demo'                        => 0,
        'currencies_available'           => bag(@all_currencies),
        'linkable_to_different_currency' => 0,
        'linkable_wallet_types'          => [],
        'linkable_wallet_currencies'     => bag(@all_currencies),
    };
    my $expected_wallet = {
        'services'             => [],
        'is_demo'              => 0,
        'currencies_available' => bag(@all_currencies),
    };
    my $params = {
        token => $token,
        args  => {$method => 1}};
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result->{trading}->{test}, $expected_trading, 'Trading account is correct - no group, no linkable wallet, no currency restruction';
    cmp_deeply $result->{trading}->{test}, $expected_trading, 'Wallet account is correct - no linkage attributes';

    my $mock_account_type = Test::MockModule->new('BOM::Config::AccountType');
    $mock_account_type->redefine(currency_types => [qw/fiat/]);
    $expected_trading->{currencies_available}       = bag(qw/EUR GBP USD AUD/);
    $expected_trading->{linkable_wallet_currencies} = bag(qw/EUR GBP USD AUD/);
    $result                                         = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result->{trading}->{test}, $expected_trading, 'Currencies are correctly limited to fiat';

    $mock_account_type->redefine(currencies => [qw/EUR GBP BTC LTC/]);
    $expected_trading->{currencies_available}       = bag(qw/EUR GBP/);
    $expected_trading->{linkable_wallet_currencies} = bag(qw/EUR GBP/);
    $result                                         = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result->{trading}->{test}, $expected_trading, 'Currencies are filterd by name - currency type limitation is also applied';

    $mock_account_type->redefine(currency_types => []);
    $expected_trading->{currencies_available}       = bag(qw/EUR GBP BTC LTC/);
    $expected_trading->{linkable_wallet_currencies} = bag(qw/EUR GBP BTC LTC/);
    $result                                         = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result->{trading}->{test}, $expected_trading, 'Currencies are filterd by name - currency type limitation is removed';

    $mock_account_type->redefine(currencies_by_landing_company => {mlataivest => ['EUR USD']});
    $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result->{trading}->{test}, $expected_trading, 'MF limitation has no effect on CR';

    $mock_account_type->redefine(currencies_by_landing_company => {svg => [qw/EUR USD/]});
    $expected_trading->{currencies_available}       = bag(qw/EUR/);
    $expected_trading->{linkable_wallet_currencies} = bag(qw/EUR/);
    $result                                         = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result->{trading}->{test}, $expected_trading,
        'Landning company currency limitation is applied along with general currency limitation';

    $mock_account_type->redefine(currencies => []);
    $expected_trading->{currencies_available}       = bag(qw/EUR USD/);
    $expected_trading->{linkable_wallet_currencies} = bag(qw/EUR USD/);
    $result                                         = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result->{trading}->{test}, $expected_trading, 'Only landning company currency limitation is applied';

    $mock_account_type->redefine(linkable_to_different_currency => 1);
    $expected_trading->{linkable_to_different_currency} = 1;
    $expected_trading->{linkable_wallet_currencies}     = bag(@all_currencies);
    $result                                             = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result->{trading}->{test}, $expected_trading,
        'All currencies are available for linkage if the account type can link to different currencies';

    $mock_account_type->redefine(is_demo => 1);
    $expected_trading->{is_demo}                    = 1;
    $expected_trading->{linkable_wallet_currencies} = bag(qw/EUR USD/);
    $result                                         = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    cmp_deeply $result->{trading}->{test}, $expected_trading, 'Linkable currencies are limted for demo accounts';

    $mock_category->unmock_all;
    $mock_account_type->unmock_all;
};

done_testing();
