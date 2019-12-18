use strict;
use warnings;
use BOM::Test::RPC::Client;
use BOM::User;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use utf8;
use Data::Dumper;
use BOM::Config::Runtime;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

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
    is($client->account->currency_code(), 'GBP', 'default account set to GBP');
};

subtest 'Can change fiat -> fiat before first deposit' => sub {
    subtest 'Change to EUR' => sub {
        $params->{currency} = 'EUR';
        $c->call_ok($method, $params)->has_no_error;
        is($c->result->{status},              1,     'set currency succeeded');
        is($client->account->currency_code(), 'EUR', 'currency successfully changed to EUR');
    };

    subtest 'Change back to USD' => sub {
        $params->{currency} = 'USD';
        $c->call_ok($method, $params)->has_no_error;
        is($c->result->{status},              1,     'set currency succeeded');
        is($client->account->currency_code(), 'USD', 'currency successfully changed back to USD');
    };
};

subtest 'Currency locks if an MT5 account is opened' => sub {
    my $mocked_user = Test::MockModule->new(ref($client->user));
    $mocked_user->mock('mt5_logins', sub { return 'MT0001' });

    subtest 'Changing currency on account with transactions should fail' => sub {
        $params->{currency} = 'EUR';
        $c->call_ok($method, $params)->has_error->error_message_is('Change of currency is not allowed due to an existing MT5 account.',
            'changing currency is not allowed after MT5 account opening')->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
    };

    $mocked_user->unmock_all;
};

my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $client->user_id()});
$client->user->add_client($client2);
$client2->set_default_account('BTC');
my $token2 = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client2->loginid);

subtest 'Currency can\'t be changed to currency of another account' => sub {

    subtest 'Changing currency to currency of another account' => sub {
        $params->{currency} = 'BTC';
        $c->call_ok($method, $params)->has_error->error_message_is(
            'Please note that you are limited to only one BTC account.',
            'changing currency is not allowed if another account has that currency set'
        )->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
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
    )->transaction_id;

    subtest 'Changing currency on account with transactions should fail' => sub {
        $params->{currency} = 'EUR';
        $c->call_ok($method, $params)->has_error->error_message_is(
            'Change of currency is not allowed for an existing account with previous deposits.',
            'client can\'t change fiat currency once there\'s a transaction linked to the account'
        )->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
    };
};

subtest 'Cannot change currency of crypto account' => sub {

    $params->{token} = $token2;

    subtest 'Cannot change crypto -> crypto' => sub {
        $params->{currency} = 'BTC';
        $c->call_ok($method, $params)->has_error->error_message_is('Account currency is set to cryptocurrency. Any change is not allowed.',
            'client can\'t change crypto currency account')->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
    };

    subtest 'Cannot change crypto -> crypto' => sub {
        $params->{currency} = 'EUR';
        $c->call_ok($method, $params)->has_error->error_message_is('Account currency is set to cryptocurrency. Any change is not allowed.',
            'client can\'t change crypto currency account')->error_code_is('CurrencyTypeNotAllowed', 'error code is correct');
    };
};

done_testing();

