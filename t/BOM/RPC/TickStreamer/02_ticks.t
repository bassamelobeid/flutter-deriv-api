use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Date::Utility;

use BOM::Test::RPC::Client;

use utf8;

my ($t, $rpc_ct, $result);
my $method = 'ticks';

my $params = {language => 'EN'};

$t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
$rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);

subtest 'validate_ticks' => sub {
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if there is no symbol param')
        ->error_message_is('Symbol  invalid.', 'It should return error if there is no symbol param');

    $params->{symbol} = 'wrong';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if there is wrong symbol param')
        ->error_message_is('Symbol wrong invalid.', 'It should return error if there is wrong symbol param');

    $params->{symbol} = 'HSI';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('NoRealtimeQuotes', 'It should return error if realtime quotes not available for this symbol')
        ->error_message_is('Realtime quotes not available for HSI.', 'It should return error if realtime quotes not available for this symbol');

    set_fixed_time(Date::Utility->new('2016-07-24')->epoch);
    $params->{symbol} = 'frxUSDJPY';
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('MarketIsClosed', 'It should return error if market is closed')
        ->error_message_is('This market is presently closed.', 'It should return error if market is closed');
    restore_time();
};

done_testing();
