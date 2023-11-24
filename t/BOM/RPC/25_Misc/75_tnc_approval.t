use strict;
use warnings;
use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User::Client;
use BOM::Config::Runtime;
use BOM::Platform::Token::API;
use BOM::RPC::v3::Accounts;
use BOM::RPC::v3::Utility;
use BOM::RPC::v3::Static;
use Email::Stuffer::TestLinks;

## TRICKY but works
my $version    = 1;
my $mock_class = ref(BOM::Config::Runtime->instance->app_config->cgi);
(my $fname = $mock_class) =~ s!::!/!g;
$INC{$fname . '.pm'} = 1;
my $mock_t_c_version = Test::MockModule->new($mock_class);
$mock_t_c_version->mock('terms_conditions_versions', sub { '{ "deriv": "Version ' . $version . '"}' });

# Mocking all of the necessary exchange rates in redis.
my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
my @all_currencies      = qw(EUR ETH AUD eUSDT tUSDT BTC LTC UST USDC USD GBP);

for my $currency (@all_currencies) {
    $redis_exchangerates->hmset(
        'exchange_rates::' . $currency . '_USD',
        quote => 1,
        epoch => time
    );
}

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
my $test_loginid = $test_client->loginid;
my $user         = BOM::User->create(
    email    => $test_client->email,
    password => BOM::User::Password::hashpw('jskjd8292922'));
$user->add_client($test_client);

my $res = BOM::RPC::v3::Static::website_status({country_code => ''});
is $res->{terms_conditions_version}, 'Version 1';

# cleanup
BOM::Platform::Token::API->new->remove_by_loginid($test_loginid);

$res = BOM::RPC::v3::Accounts::tnc_approval({client => $test_client});
is_deeply $res, {status => 1};

$res = BOM::RPC::v3::Accounts::get_settings({
    client   => $test_client,
    language => 'EN'
});
is $res->{client_tnc_status}, 'Version 1', 'version 1';

# switch to version 2
$version = 2;

$res = BOM::RPC::v3::Static::website_status({country_code => ''});
is $res->{terms_conditions_version}, 'Version 2', 'version 2';
is_deeply $res->{supported_languages}, BOM::Config::Runtime->instance->app_config->cgi->supported_languages, 'Correct supported languages';

$res = BOM::RPC::v3::Accounts::tnc_approval({client => $test_client});
is_deeply $res, {status => 1};

$res = BOM::RPC::v3::Accounts::get_settings({
    client   => $test_client,
    language => 'EN'
});
is $res->{client_tnc_status}, 'Version 2', 'version 2';

done_testing();
