use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::MockModule;
use JSON::MaybeUTF8;

use BOM::Test::RPC::QueueClient;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;

use Test::BOM::RPC::Accounts;

my $c = BOM::Test::RPC::QueueClient->new();

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS       = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS        = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
my %financial_data = %Test::BOM::RPC::Accounts::FINANCIAL_DATA;

# Setup a test user
my $test_client    = create_client('CR',   undef, {residence => 'za'});
my $test_client_vr = create_client('VRTC', undef, {residence => 'za'});

$test_client->email($DETAILS{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);

$test_client_vr->email($DETAILS{email});
$test_client_vr->set_default_account('USD');

$test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$test_client->save;

$test_client_vr->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

$test_client->save;

my $m        = BOM::Platform::Token::API->new;
my $token    = $m->create_token($test_client->loginid,    'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

subtest 'custom new account' => sub {
    my $method = 'mt5_new_account';
    my $args   = {
        account_type => 'demo',
        email        => $DETAILS{email},
        name         => $DETAILS{name},
        mainPassword => $DETAILS{password}{main},
        leverage     => 100,
        server       => 'p01_ts03'
    };
    my $params = {
        language => 'EN',
        token    => $token_vr,
        args     => $args,
    };

    note('demo account cannot select trade server');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(0);
    $c->call_ok($method, $params)->has_error->error_code_is('InvalidServerInput')
        ->error_message_is('Input parameter \'server\' is not supported for the account type.');

    note('financial account cannot select trade server');
    $args->{account_type}     = 'financial';
    $args->{mt5_account_type} = 'financial';
    $c->call_ok($method, $params)->has_error->error_code_is('InvalidServerInput')
        ->error_message_is('Input parameter \'server\' is not supported for the account type.');

    note('gaming account can select trade server');
    delete $args->{mt5_account_type};
    $args->{account_type} = 'gaming';

    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
    $c->call_ok($method, $params)->has_no_error('client from south africa can select real->p01_ts03');
    is($c->result->{login},           'MTR' . $ACCOUNTS{'real\p01_ts03\synthetic\svg_std_usd\01'}, 'result->{login}');
    is($c->result->{balance},         0,                                                           'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                                                      'Display balance is "0.00" upon creation');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $args->{server} = 'p01_ts02';
    $c->call_ok($method, $params)->has_no_error('client from south africa can have multiple synthetic account');
    is($c->result->{login},           'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_std_usd\01'}, 'result->{login}');
    is($c->result->{balance},         0,                                                           'Balance is 0 upon creation');
    is($c->result->{display_balance}, '0.00',                                                      'Display balance is "0.00" upon creation');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $c->call_ok($method, $params)->has_error('error from duplicate mt5_new_account')
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account');
};

subtest 'non-Ireland client new account check' => sub {
    my $method = 'mt5_new_account';
    my $args   = {
        account_type => 'gaming',
        email        => 'abc' . $DETAILS{email},
        name         => $DETAILS{name},
        mainPassword => $DETAILS{password}{main},
        leverage     => 100,
        server       => 'p01_ts01'
    };
    my $params = {
        language => 'EN',
        token    => $token_vr,
        args     => $args,
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    note('demo account cannot select trade server');
    BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts02->all(0);
    $c->call_ok($method, $params)->has_error->error_code_is('PermissionDenied')->error_message_is('Permission denied.');
};

subtest 'use default routing rule if server is not provided' => sub {
    $test_client->myaffiliates_token('FakeToken');
    $test_client->save;

    my $mocked = Test::MockModule->new('BOM::RPC::v3::MT5::Account');
    # fake affiliate id
    $mocked->mock(_get_ib_affiliate_id_from_token => sub { return 12345 });

    my $expected_agent_id = 1001;
    _add_affiliate_account(
        $test_client,
        {
            server         => 'p01_ts02',
            mt5_account_id => $expected_agent_id,
            binary_user_id => $test_client->user->id,
            affiliate_id   => 12345,
            account_type   => 'technical'
        });
    my $method = 'mt5_new_account';
    my $args   = {
        account_type         => 'gaming',
        email                => 'abc' . $DETAILS{email},
        name                 => $DETAILS{name},
        mainPassword         => $DETAILS{password}{main},
        leverage             => 100,
        mt5_account_type     => 'financial',
        mt5_account_category => 'swap_free',

    };
    my $params = {
        language => 'EN',
        token    => $token_vr,
        args     => $args,
    };

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    note('no server as user input');
    my $res = $c->call_ok($method, $params)->has_no_error->result;
    is $res->{login},        'MTR' . $ACCOUNTS{'real\p01_ts02\synthetic\svg_sf_usd'}, 'defaulted to account on real->p01_ts02';
    is $res->{account_type}, 'gaming', 'gaming';
    is $res->{agent},        $expected_agent_id, 'agent linked ' . $expected_agent_id;
};

sub _add_affiliate_account {
    my ($client, $args) = @_;

    $client->user->dbic->run(
        ping => sub {
            $_->selectrow_array(
                q{SELECT * FROM mt5.add_affiliate_account(?, ?, ?, ?, ?)},
                undef, $args->{server}, $args->{mt5_account_id},
                $args->{affiliate_id}, $args->{binary_user_id},
                $args->{account_type});
        });
}

done_testing();
