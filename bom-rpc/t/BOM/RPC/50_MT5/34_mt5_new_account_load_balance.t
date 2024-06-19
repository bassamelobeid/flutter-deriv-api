use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use BOM::Config::Runtime;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %accounts = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %details  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

# Setup a test user
my $password = 's3kr1t';
my $hash_pwd = BOM::User::Password::hashpw($password);
my $user     = BOM::User->create(
    email    => $details{email},
    password => $hash_pwd,
);
my $test_client    = create_client('CR');
my $test_client_vr = create_client('VRTC');

$test_client->email($details{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id($user->id);
$test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$test_client->save;

$test_client_vr->email($details{email});
$test_client_vr->set_default_account('USD');
$test_client_vr->binary_user_id($user->id);
$test_client_vr->save;

$user->update_trading_password($details{password}{main});
$user->add_client($test_client);
$user->add_client($test_client_vr);

#$test_client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%financial_data)});
#$test_client->save;

my $m        = BOM::Platform::Token::API->new;
my $token    = $m->create_token($test_client->loginid,    'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

subtest 'new synthetic account' => sub {
    # set weight of p01_ts02 and p01_ts03 to 0
    BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02(0);
    BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03(0);

    $test_client->user->update_trading_password($details{password}{main});
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type => 'demo',
            country      => 'mt',
            email        => $details{email},
            name         => $details{name},
            mainPassword => $details{password}{main},
            leverage     => 100,
        },
    };
    my $result = $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account without investPassword')->result;
    is($result->{login},           'MTD' . $accounts{'demo\p01_ts01\synthetic\svg_std_usd'}, 'result->{login}');
    is($result->{balance},         10000,                                                    'Balance is 10000 upon creation');
    is($result->{display_balance}, '10000.00',                                               'Display balance is "10000.00" upon creation');
};

subtest 'new financial account' => sub {

    # With three MT5 server at this point, we are testing an equal load balance for all
    BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts03(33);
    BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts02(33);
    BOM::Config::Runtime->instance->app_config->system->mt5->load_balance->demo->all->p01_ts01(33);

    my $mocked = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    $mocked->mock('_rand', sub { return 0.100 });
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'demo',
            mt5_account_type => 'financial',
            country          => 'mt',
            email            => $details{email},
            name             => $details{name},
            mainPassword     => $details{password}{main},
            leverage         => 100,
        },
    };

    my $result = $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account without investPassword')->result;

    $result->{login} =~ /([0-9]+)/;
    my $loginid = $1;
    my ($group_name) = grep { $accounts{$_} eq $loginid } keys %accounts;

    is($result->{login},           'MTD' . $accounts{$group_name}, 'result->{login}');
    is($result->{balance},         10000,                          'Balance is 10000 upon creation');
    is($result->{display_balance}, '10000.00',                     'Display balance is "10000.00" upon creation');
};

done_testing();
