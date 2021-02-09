use Test::Most;

use BOM::Config::Runtime;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test1@bin.com',
});

my $user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);

subtest 'BOM::User::payment_accounts_limit' => sub {
    subtest 'returns default limit when not overrided by app config' => sub {
        BOM::Config::Runtime->instance->app_config->payments->custom_payment_accounts_limit_per_user('{}');
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 4;
        is($user->payment_accounts_limit(), 4);
    };

    subtest 'returns the overriden value when available' => sub {
        BOM::Config::Runtime->instance->app_config->payments->custom_payment_accounts_limit_per_user('{"' . $user->{id} . '":3}');
        BOM::Config::client_limits()->{max_payment_accounts_per_user} = 4;
        is($user->payment_accounts_limit(), 3);
    };
};

done_testing;
