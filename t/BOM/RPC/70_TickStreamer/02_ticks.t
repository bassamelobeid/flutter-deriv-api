use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Date::Utility;

use BOM::Test::RPC::QueueClient;

use utf8;

my ($rpc_ct, $result);
my $method = 'ticks';

my $params = {language => 'EN'};

$rpc_ct = BOM::Test::RPC::QueueClient->new();

my $instance                = BOM::Config::Runtime->instance;
my $mocked_offerings_config = Test::MockModule->new(ref $instance);
$mocked_offerings_config->mock('get_offerings_config' => sub { return {'suspend_underlying_symbols' => ['LGTM']} });

subtest 'validate_ticks' => sub {
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if there is no symbol param')
        ->error_message_is('Symbol  is invalid.', 'It should return error if there is no symbol param');

    $params->{symbol} = 'wrong';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if there is wrong symbol param')
        ->error_message_is('Symbol wrong is invalid.', 'It should return error if there is wrong symbol param');

    $params->{symbol} = 'LGTM';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if there is wrong symbol param')
        ->error_message_is('Symbol LGTM is invalid.', 'It should return error if there is wrong symbol param');

    $mocked_offerings_config->unmock_all();
    set_fixed_time(Date::Utility->new('2016-07-24')->epoch);
    $params->{symbol} = 'frxUSDJPY';
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('MarketIsClosed', 'It should return error if market is closed')
        ->error_message_is('This market is presently closed.', 'It should return error if market is closed');
    restore_time();
};

done_testing();
