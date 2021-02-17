use Test::Most;

use BOM::Config::Runtime;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test1@bin.com',
});

my $user = BOM::User->create(
    email          => $client->email,
    password       => "hello",
    email_verified => 1,
);

subtest 'BOM::User::Client::payment_accounts_limit' => sub {
    subtest 'returns default limit when not overrided by app config or broker code' => sub {
        BOM::Config::Runtime->instance->app_config->payments->custom_payment_accounts_limit_per_user('{}');
        BOM::Config::client_limits()->{max_client_payment_accounts_per_broker_code} = undef;
        BOM::Config::client_limits()->{max_payment_accounts_per_user}               = 4;
        is($client->payment_accounts_limit(), 4);
    };

    subtest 'returns the override value by broker code if no overriden value by app config is there' => sub {
        BOM::Config::Runtime->instance->app_config->payments->custom_payment_accounts_limit_per_user('{}');
        BOM::Config::client_limits()->{max_client_payment_accounts_per_broker_code}->{CR} = 5;
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 4;
        is($client->payment_accounts_limit(), 5);
    };

    subtest 'returns the overriden value by app_config when available' => sub {
        BOM::Config::Runtime->instance->app_config->payments->custom_payment_accounts_limit_per_user('{"' . $client->user->{id} . '":3}');
        BOM::Config::client_limits()->{max_client_payment_accounts_per_broker_code}->{CR} = 5;
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 4;
        is($client->payment_accounts_limit(), 3);
    };
};

done_testing;
