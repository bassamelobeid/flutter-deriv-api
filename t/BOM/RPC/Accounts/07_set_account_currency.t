use strict;
use warnings;
use BOM::Test::RPC::Client;
use BOM::User;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use utf8;
use Data::Dumper;
use BOM::Config::Runtime;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $email = 'dummy@binary.com';
my $user  = BOM::User->create(
    email    => $email,
    password => 'test'
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;
$user->add_client($client);
is $client->account, undef, 'new client has no default account';

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

my $method = 'set_account_currency';
my $params = {
    language => 'EN',
    token    => 12345
};

subtest 'Error checks' => sub {

    subtest 'Error with invalid token' => sub {
        $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');
    };

    subtest 'Error for disabled account' => sub {
        $params->{token} = $token;
        $client->status->set('disabled', 1, 'test disabled');
        $c->call_ok($method, $params)->has_error->error_message_is('This account is unavailable.', 'check invalid token');
        $client->status->clear_disabled;
    };

    subtest 'Error for non-currency' => sub {
        $params->{currency} = 'not_allowed';
        $c->call_ok($method, $params)->has_error->error_message_is('The provided currency not_allowed is not applicable for this account.',
            'currency not applicable for this client')->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
    };

    subtest 'Error for currency not available on this landing company' => sub {
        $params->{currency} = 'JPY';
        $c->call_ok($method, $params)
            ->has_error->error_message_is('The provided currency JPY is not applicable for this account.', 'currency not applicable for this client')
            ->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
    };

    subtest 'Error for cryptocurrency when cryptocashier is unavailable' => sub {
        BOM::Config::Runtime->instance->app_config->system->suspend->cryptocashier(1);
        $params->{currency} = 'BTC';
        $c->call_ok($method, $params)
            ->has_error->error_message_is('The provided currency BTC is not selectable at the moment.', 'currency not applicable for this client')
            ->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
        BOM::Config::Runtime->instance->app_config->system->suspend->cryptocashier(0);
    };
};

subtest 'Set currency of account without a currency' => sub {

    $params->{currency} = 'GBP';
    $c->call_ok($method, $params)->has_no_error;
    is($c->result->{status}, 1, 'set currency ok');

    isnt($client->account, undef, 'default account set');
    is($client->account->currency_code, 'GBP', 'default account set to GBP');
};

subtest 'Currency can be changed while there are no transactions' => sub {

    subtest 'Currency unlocked status is returned' => sub {
        is($client->account->last_transaction_id, undef, 'account has no transactions yet');
        $c->call_ok('get_account_status', {token => $token})->has_no_error;
        is(grep(/^currency_unlocked$/, @{$c->result->{status}}), 1, 'currency unlocked status presents when no transaction exist');
    };

    subtest 'Can change fiat -> fiat' => sub {
        $params->{currency} = 'EUR';
        $c->call_ok($method, $params)->has_no_error;
        is($c->result->{status},            1,     'set currency succeeded');
        is($client->account->currency_code, 'EUR', 'currency successfully changed to EUR');
    };

    subtest 'Can change fiat -> crypto' => sub {
        $params->{currency} = 'BTC';
        $c->call_ok($method, $params)->has_no_error;
        is($c->result->{status},            1,     'set currency succeeded');
        is($client->account->currency_code, 'BTC', 'currency successfully changed to BTC');
    };

    subtest 'Can change crypto -> fiat' => sub {
        $params->{currency} = 'USD';
        $c->call_ok($method, $params)->has_no_error;
        is($c->result->{status},            1,     'set currency succeeded');
        is($client->account->currency_code, 'USD', 'currency successfully changed to USD');
    };
};

subtest 'Currency locks after a transaction is made' => sub {

    # Create transaction by crediting client's account — this should trigger
    # a lock for the account's currency
    my $transaction_id = $client->payment_legacy_payment(
        currency     => 'USD',
        amount       => 1,
        payment_type => "ewallet",
        remark       => "credit",
        staff        => "test",
    )->id;

    subtest 'Currency unlocked status is no longer indicated' => sub {
        ok($client->account->last_transaction_id, 'account should have transaction after payment');
        $c->call_ok('get_account_status', $params)->has_no_error;
        is(grep(/^currency_unlocked$/, $c->result->{status}), 0, 'changing currency is not allowed after transaction');
    };

    subtest 'Changing currency on account with transactions should fail' => sub {
        $params->{currency} = 'EUR';
        $c->call_ok($method, $params)->has_error->error_message_is('This account already has a currency set and cannot be changed because transactions have been made.',
            'client can\'t change fiat currency once there\'s a transaction linked to the account')
            ->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
    };
};

done_testing();

