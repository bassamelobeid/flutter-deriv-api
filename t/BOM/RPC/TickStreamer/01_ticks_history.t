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

$t = Test::Mojo->new('BOM::RPC');
$rpc_ct = Test::BOM::RPC::Client->new( ua => $t->app->ua );

subtest 'Initialization' => sub {
    lives_ok {
        my ($fill_start, $populator, @ticks, $fh);
        my $work_dir = File::Temp->newdir();
        my $buffer = BOM::Feed::Buffer::TickFile->new(base_dir => "$work_dir");

        # Insert HSI data ticks
        $fill_start = $now->minus_time_interval('7h');
        $populator = BOM::Feed::Populator::InsertTicks->new({
            symbols            => [qw/ HSI /],
            last_migrated_time => $fill_start,
            buffer             => $buffer,
        });

        open($fh, "<", "/home/git/regentmarkets/bom-test/feed/combined/HSI/17-Dec-12.fullfeed") or die $!;
        @ticks = <$fh>;
        close $fh;

        $populator->insert_to_db({
            ticks  => \@ticks,
            date   => $fill_start,
            symbol => 'HSI',
        });

        # Insert RDYANG data ticks
        $fill_start = $now->minus_time_interval('1d7h');
        $populator = BOM::Feed::Populator::InsertTicks->new({
            symbols            => [qw/ RDYANG /],
            last_migrated_time => $fill_start,
            buffer             => $buffer,
        });
        open($fh, "<", "/home/git/regentmarkets/bom-test/feed/combined/frxUSDJPY/13-Apr-12.fullfeed") or die $!;
        @ticks = <$fh>;
        close $fh;
        foreach my $i (0..1) {
            $populator->insert_to_db({
                ticks  => \@ticks,
                date   => $fill_start->plus_time_interval("${i}d"),
                symbol => 'RDYANG',
            });
        }

        # Insert frxUSDJPY data ticks
        BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/14-Mar-12.dump');
    } 'Setup ticks';
};

# TODO ???
my $module = Test::MockModule->new('BOM::Database::FeedDB');
$module->mock('read_dbh', sub { BOM::Database::FeedDB::write_dbh });
# /TODO

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
    my $start = $now->minus_time_interval('7h');
    my $end = $start->plus_time_interval('1m');

    $params->{args}->{ticks_history} = 'frxUSDJPY';
    $params->{args}->{end} = $end->epoch;
    $params->{args}->{start} = $start->epoch;
    $params->{args}->{style} = 'ticks';

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{type}, 'history', 'Result type should be history';
    is scalar( @{ $result->{data}->{history}->{times} } ), 47, 'It should return all ticks between start and end';
    is scalar( @{ $result->{data}->{history}->{prices} } ), 47, 'It should return all ticks between start and end';

    $params->{args}->{count} = 10;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is scalar( @{ $result->{data}->{history}->{times} } ), $params->{args}->{count}, 'It should return last 10 ticks if count sent with start and end time';
    is scalar( @{ $result->{data}->{history}->{prices} } ), $params->{args}->{count}, 'It should return last 10 ticks if count sent with start and end time';
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $end->epoch, 'It should return last 10 ticks if count sent with start and end time';

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
};

subtest 'history data style' => sub {
    my $start = $now->minus_time_interval('5h');
    my $end = $start->plus_time_interval('2h');

    $params->{args} = {};
    $params->{args}->{ticks_history} = 'HSI';
    $params->{args}->{end} = $end->epoch;
    $params->{args}->{start} = $start->epoch;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{publish}, 'tick', 'It should return ticks style data by default';

    $params->{args}->{style} = 'invalid';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error
        ->has_error
        ->error_code_is('InvalidStyle', 'It should return error if sent invalid style')
        ->error_message_is('Стиль invalid недействителен', 'It should return error if sent invalid style');

    delete $params->{args}->{style};
    $params->{args}->{granularity} = 60;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{type}, 'candles', 'It should return candles';

    $params->{args}->{style} = 'candles';
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{type}, 'candles', 'It should return candles';

    delete $params->{args}->{granularity};
    $params->{args}->{end} = $start->plus_time_interval('40s')->epoch;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{$result->{data}->{candles}}, 1, 'It should return only 1 candle if start end diff lower than granularity';
    is_deeply   [sort keys %{ $result->{data}->{candles}->[0] } ],
                [sort qw/ open high epoch low close /];

    $start = $now->minus_time_interval('1d7h')->plus_time_interval('1m');
    $params->{args}->{start} = $start->epoch;
    $params->{args}->{end} = $start->plus_time_interval('1d1m1s')->epoch;
    $params->{args}->{granularity} = 60*60*24;
    $params->{args}->{ticks_history} = 'RDYANG';
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    my $daily_candles_rdyang_first_open = $result->{data}->{candles}->[0]->{open};
    $start = $now->minus_time_interval('1d7h');
    $params->{args}->{style} = 'ticks';
    $params->{args}->{start} = $start->epoch;
    $params->{args}->{end} = $start->plus_time_interval('1s')->epoch;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $daily_candles_rdyang_first_open, $result->{data}->{history}->{prices}->[0], 'For the underlying nocturne, for daily ohlc, it should return ticks started from day started time';

    $start = $now->minus_time_interval('5h');
    $end = $start->plus_time_interval('30m');
    $params->{args} = {};
    $params->{args}->{ticks_history} = 'HSI';
    $params->{args}->{end} = $end->epoch;
    $params->{args}->{start} = $start->epoch;
    $params->{args}->{style} = 'candles';

    $params->{args}->{granularity} = 60*5;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{ $rpc_ct->result->{data}->{candles} }, (($end->minute - $start->minute)/5 + 1), 'If granularity is 60*5 it should return candles count equals minute difference/5';

    $params->{args}->{granularity} = 60;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{ $rpc_ct->result->{data}->{candles} }, ($end->minute - $start->minute + 1), 'Granularity is 60 by default it should return candles count equals minute difference';
    is $params->{args}->{start}, $result->{data}->{candles}->[0]->{epoch};
    is $params->{args}->{end}, $result->{data}->{candles}->[-1]->{epoch};
    my $first_candle_close = $result->{data}->{candles}->[0]->{close};
    my $end_candle_open = $result->{data}->{candles}->[-1]->{open};

    $start = $start->plus_time_interval('30s');
    $end = $end->plus_time_interval('30s');
    $params->{args}->{start} = $start->epoch;
    $params->{args}->{end} = $end->epoch;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{data}->{candles}->[0]->{close}, $first_candle_close, 'It should align candles by close time';
    is $result->{data}->{candles}->[-1]->{open}, $end_candle_open, 'It should align candles by open time';

    $params->{args}->{count} = 1;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{ $result->{data}->{candles} }, 1, 'It should return one last candle';
    is $result->{data}->{candles}->[-1]->{open}, $end_candle_open, 'It should return one last candle';
};

done_testing();
