use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use Date::Utility;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::FeedTestDatabase qw/:init/;

use utf8;

set_fixed_time(Date::Utility->new('2012-03-14 23:59:58')->epoch);

my ( $t, $rpc_ct, $result );
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

    # TODO ???
    my $module = Test::MockModule->new('BOM::Database::FeedDB');
    $module->mock('read_dbh', sub { BOM::Database::FeedDB::write_dbh });
    # /TODO

    BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/14-Mar-12.dump');
    my $start = Date::Utility->new('2012-03-14 00:00:00');
    my $end = $start->plus_time_interval('1m');

    $params->{args}->{ticks_history} = 'frxUSDJPY';
    $params->{args}->{end} = $end->epoch;
    $params->{args}->{start} = $start->epoch;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{publish}, 'tick', 'It should return ticks data by default';
    is $result->{type}, 'history', 'Result type should be history';
    is scalar( @{ $result->{data}->{history}->{times} } ), 47, 'It should return all ticks between start and end';
    is scalar( @{ $result->{data}->{history}->{prices} } ), 47, 'It should return all ticks between start and end';

    $params->{args}->{count} = 10;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is scalar( @{ $result->{data}->{history}->{times} } ), $params->{args}->{count}, 'It should return last 10 ticks if count sent with start and end time';
    is scalar( @{ $result->{data}->{history}->{prices} } ), $params->{args}->{count}, 'It should return last 10 ticks if count sent with start and end time';
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $end->epoch, 'It should return last 10 ticks if count sent with start and end time';

    $params->{args}->{style} = 'invalid';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error
        ->has_error
        ->error_code_is('InvalidStyle', 'It should return error if sent invalid style')
        ->error_message_is('Стиль invalid недействителен', 'It should return error if sent invalid style');

    # print Dumper scalar @{ $rpc_ct->result->{data}->{history}->{times} };
    # print Dumper( Date::Utility->new($rpc_ct->result->{data}->{history}->{times}->[0])->datetime_yyyymmdd_hhmmss );
    # print Dumper( Date::Utility->new($rpc_ct->result->{data}->{history}->{times}->[-1])->datetime_yyyymmdd_hhmmss );
    # print Dumper $rpc_ct->result;
    # print $rpc_ct->result->{error}->{message_to_client};
};

done_testing();
