use strict;
use warnings;

use Test::MockTime qw/:all/;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use MojoX::JSON::RPC::Client;
use Data::Dumper;
use Date::Utility;
use File::Temp;

use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::FeedTestDatabase qw/:init/;
use BOM::Feed::Buffer::TickFile;
use BOM::Feed::Populator::InsertTicks;

use utf8;

my ( $t, $rpc_ct, $result );
my $method = 'ticks_history';

my $params = {
    language => 'RU',
    source => 1,
    country => 'ru',
};

my $now = Date::Utility->new('2012-03-14 07:00:00');
set_fixed_time($now->epoch);

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );
    } 'Initial RPC server and client connection';

    lives_ok {
        # Insert HSI data ticks
        my $work_dir = File::Temp->newdir();
        my $buffer = BOM::Feed::Buffer::TickFile->new(base_dir => "$work_dir");
        my $date = $now->minus_time_interval('7h');
        my $populator = BOM::Feed::Populator::InsertTicks->new({
            symbols            => [qw/ HSI /],
            last_migrated_time => $date,
            buffer             => $buffer,
        });

        open(my $fh, "<", "/home/git/regentmarkets/bom-test/feed/combined/HSI/17-Dec-12.fullfeed") or die;
        my @ticks = <$fh>;
        close $fh;

        $populator->insert_to_db({
            ticks  => \@ticks,
            date   => $date,
            symbol => 'HSI',
        });

        # Insert frxUSDJPY data ticks
        BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/14-Mar-12.dump');
    } 'Setup ticks';
};

subtest 'ticks_history' => sub {
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
};

subtest '_validate_start_end' => sub {

    # TODO ???
    my $module = Test::MockModule->new('BOM::Database::FeedDB');
    $module->mock('read_dbh', sub { BOM::Database::FeedDB::write_dbh });
    # /TODO

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

    $params->{args}->{style} = 'ticks';
    $params->{args}->{end} = $end->minus_time_interval((365*4).'d')->epoch;
    $params->{args}->{start} = $start->minus_time_interval((365*4).'d')->epoch;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $now->epoch, 'It should return latest ticks if client requested ticks older than 3 years';

    $params->{args}->{start} = $now->minus_time_interval('1m')->epoch;
    $params->{args}->{end} = $end->epoch;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $now->epoch, 'It should return latest ticks if client start time bigger than end time';

    $params->{args}->{end} = 'invalid';
    $params->{args}->{count} = 10;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $now->epoch, 'It should return latest ticks for last day if client sent invalid end time';

    $params->{args}->{start} = 'invalid';
    $params->{args}->{end} = $now->minus_time_interval('6h30m')->epoch;
    $params->{args}->{count} = 2000;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $rpc_ct->result->{data}->{history}->{times}->[0], $now->minus_time_interval('7h')->epoch, 'It should return latest existed tick for last day if client sent invalid start time';

    $params->{args}->{start} = $now->minus_time_interval('1d')->epoch;
    $params->{args}->{end} = $now->epoch;
    delete $params->{args}->{count};
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{ $rpc_ct->result->{data}->{history}->{times} }, 500, 'It should return 500 ticks by default';

    $params->{args}->{count} = 'invalid';
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{ $rpc_ct->result->{data}->{history}->{times} }, 500, 'It should return 500 ticks if sent invalid count';

    $params->{args}->{count} = 10000;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{ $rpc_ct->result->{data}->{history}->{times} }, 500, 'It should return 500 ticks if sent very big count';

    $params->{args}->{ticks_history} = 'HSI';
    $params->{args}->{start} = $now->minus_time_interval('1h30m')->epoch;
    $params->{args}->{end} = $now->plus_time_interval('1d')->epoch;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $now->epoch - BOM::Market::Underlying->new('HSI')->delay_amount*60, 'It should return last licensed tick for delayed symbol';
    my $ticks_count_without_adjust_time = @{ $rpc_ct->result->{data}->{history}->{times} };

    $params->{args}->{adjust_start_time} = 1;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    ok @{ $rpc_ct->result->{data}->{history}->{times} } > $ticks_count_without_adjust_time, 'If sent adjust_start_time param then it should return ticks with shifted start time';

    set_fixed_time($now->plus_time_interval('5h')->epoch);
    my $ul = BOM::Market::Underlying->new('HSI');
    $params->{args}->{end} = $ul->exchange->closing_on($now)->plus_time_interval('1m')->epoch;
    $params->{args}->{start} = $ul->exchange->closing_on($now)->minus_time_interval('39m')->epoch;
    delete $params->{args}->{count};
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{data}->{history}->{times}->[0], $ul->exchange->closing_on($now)->minus_time_interval('40m')->epoch, 'If exchange close at end time and sent adjust_start_time then it should shift back start time';

    # print Dumper scalar @{ $rpc_ct->result->{data}->{history}->{times} };
    # print Dumper( Date::Utility->new($now->epoch - BOM::Market::Underlying->new('HSI')->delay_amount*60)->datetime_yyyymmdd_hhmmss );
    # print Dumper( Date::Utility->new($rpc_ct->result->{data}->{history}->{times}->[-1])->datetime_yyyymmdd_hhmmss );
    # print Dumper( $now->minus_time_interval('1d')->datetime_yyyymmdd_hhmmss );
    # print Dumper $rpc_ct->result;
    # print Dumper $rpc_ct->response;
    # print $rpc_ct->result->{error}->{message_to_client};
};

done_testing();
