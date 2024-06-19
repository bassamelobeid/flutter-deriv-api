use strict;
use warnings;
use Test::Most;
use Dir::Self;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use lib "$Bin";

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(create_client top_up);
use BOM::Test::Suite::DSL;
use BOM::Test::RPC::QueueClient;
use Test::BOM::RPC::Accounts;

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;

# TODO: Use $suite instead of $c
my $c     = BOM::Test::RPC::QueueClient->new();
my $suite = start(
    title             => "suite_mt5.t",
    test_app          => 'BOM::RPC::Transport::Redis',
    suite_schema_path => __DIR__ . '/config/',
);
set_language 'EN';

# Setup a test user
my $test_client = create_client('CR');
$test_client->email($DETAILS{email});
$test_client->set_default_account('USD');
$test_client->binary_user_id(1);
$test_client->set_authentication('ID_DOCUMENT', {status => 'pass'});
$test_client->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->update_trading_password($DETAILS{password}{main});
$user->add_client($test_client);

my $token_api = BOM::Platform::Token::API->new;
my $token     = $token_api->create_token($test_client->loginid, 'test token', ['read', 'trade', 'payments', 'admin'],);

BOM::Config::Runtime->instance->app_config->system->mt5->suspend->real->p01_ts03->all(0);
my $mt5_account = test_sendrecv_params 'mt5_new_account/test_send.json', 'mt5_new_account/test_receive.json', $token, $DETAILS{email},
    $DETAILS{name}, $DETAILS{password}{main};
test_sendrecv_params 'mt5_get_settings/test_send.json', 'mt5_get_settings/test_receive.json', $token, $mt5_account->{login};

done_testing();
