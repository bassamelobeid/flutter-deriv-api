use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::FeedTestDatabase qw/:init/;

use utf8;

my ( $t, $rpc_ct );
my $method = 'ticks_history';

my $params = {
    language => 'RU',
    source => 1,
    country => 'ru',
};

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );
    } 'Initial RPC server and client connection';
};

subtest 'Request ticks history' => sub {
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error
        ->has_error
        ->error_code_is('InvalidSymbol', 'It should return error if there is no symbol param')
        ->error_message_is('Символ  недействителен', 'It should return error if there is no symbol param');

    $params->{args}->{ticks_history} = 'wrong';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error
        ->has_error
        ->error_code_is('InvalidSymbol', 'It should return error if there is wrong symbol param')
        ->error_message_is('Символ wrong недействителен', 'It should return error if there is wrong symbol param');

    $params->{args}->{ticks_history} = 'TOP40';
    $params->{args}->{subscribe} = '1';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error
        ->has_error
        ->error_code_is('NoRealtimeQuotes', 'It should return error if realtime quotes not available for this symbol')
        ->error_message_is('Котировки в режиме реального времени недоступны для TOP40', 'It should return error if realtime quotes not available for this symbol');
    delete $params->{args}->{subscribe};

    $params->{args}->{ticks_history} = 'R_100';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error
        ->has_no_error
        ->result_is_deeply({
            'publish' => 'tick',
            'type' => 'history',
            'data' => {
                'history' => {
                    'times' => [],
                    'prices' => [],
                },
            },
        }, 'It should return empty result if there are no end and count params, default type ticks');

    # $params->{args}->{ticks_history} = 'R_100';
    # $params->{args}->{end} = 'latest';
    # $params->{args}->{count} = '10';
    # $rpc_ct->call_ok($method, $params)
    #     ->has_no_system_error
    #     ->has_no_error
    #     ->result_is_deeply({
    #         'publish' => 'tick',
    #         'type' => 'history',
    #         'data' => {
    #             'history' => {
    #                 'times' => [],
    #                 'prices' => [],
    #             },
    #         },
    #     }, 'It should return empty result if there are no end and count params, default type ticks');



    print Dumper $rpc_ct->result;
    print $rpc_ct->result->{error}->{message_to_client};
};

done_testing();
