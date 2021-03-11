use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use BOM::Config::Runtime;
use Test::BOM::RPC::Accounts;
use BOM::RPC::v3::MT5::Account;

my $c = BOM::Test::RPC::QueueClient->new();
BOM::Config::Runtime->instance->app_config->payments->transfer_between_accounts->limits->MT5(999);

my $manager_module = Test::MockModule->new('BOM::MT5::User::Async');
$manager_module->mock(
    'deposit',
    sub {
        return Future->done({success => 1});
    },
    'withdrawal',
    sub {
        return Future->done({success => 1});
    });

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS       = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS        = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;

subtest 'frozen free gift' => sub {

    my $email  = 'promotest@binary.com';
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $DETAILS{email},
        place_of_birth => 'id',
    });
    my $user = BOM::User->create(
        email    => $DETAILS{email},
        password => 's3kr1t',
    );
    $user->add_client($client);
    $client->account('USD');
    $client->tax_identification_number('111222333');
    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});

    $client->db->dbic->dbh->do(
        q/insert into betonmarkets.promo_code (code, promo_code_type, promo_code_config, start_date, expiry_date, status, description)
        values ('PROMO1','FREE_BET','{"country":"ALL","amount":"200","currency":"ALL"}', now() - interval '1 month', now() + interval '1 month','t','test') /
    );

    $client->promo_code('PROMO1');
    $client->promo_code_status('CLAIM');
    $client->save;

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 200,
        remark   => 'Free gift',
    );

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    BOM::RPC::v3::MT5::Account::reset_throttler($client->loginid);

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'gaming',
            country      => 'mt',
            email        => $DETAILS{email},
            name         => $DETAILS{name},
            mainPassword => $DETAILS{password}{main},
            leverage     => 100,
        },
    };
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
    $c->call_ok('mt5_new_account', $params)->has_no_error('no error for mt5_new_account');

    $params->{args} = {
        from_binary => $client->loginid,
        to_mt5      => 'MTR' . $ACCOUNTS{'real03\synthetic\svg_std_usd'},
        amount      => 180,
    };
};

done_testing();

