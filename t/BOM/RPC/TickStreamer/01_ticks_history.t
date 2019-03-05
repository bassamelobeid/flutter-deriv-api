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

use BOM::Config::Chronicle;
use Quant::Framework;
use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::FeedTestDatabase qw/:init/;
use BOM::Populator::TickFile;
use BOM::Populator::InsertTicks;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use utf8;

use constant MAX_TICK_COUNT => 5000;

my ($t, $rpc_ct, $result);
my $method = 'ticks_history';

my $params = {
    language => 'EN',
    country  => 'ru',
};

my $now = Date::Utility->new('2012-03-14 07:00:00');
set_fixed_time($now->epoch);

$t = Test::Mojo->new('BOM::RPC');
$rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);

my $feed_dir = File::Temp->newdir;
$ENV{BOM_POPULATOR_ROOT} = "$feed_dir";

subtest 'Initialization' => sub {
    lives_ok {
        my ($fill_start, $populator, @ticks, $fh);
        my $work_dir = File::Temp->newdir();
        my $buffer = BOM::Populator::TickFile->new(base_dir => "$work_dir");

        # Insert HSI data ticks
        $fill_start = $now->minus_time_interval('7h');
        $populator  = BOM::Populator::InsertTicks->new({
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

        # Insert R_100 data ticks
        $fill_start = $now->minus_time_interval('1d7h');
        $populator  = BOM::Populator::InsertTicks->new({
            symbols            => [qw/ R_100 /],
            last_migrated_time => $fill_start,
            buffer             => $buffer,
        });
        open($fh, "<", "/home/git/regentmarkets/bom-test/feed/combined/frxUSDJPY/13-Apr-12.fullfeed") or die $!;
        @ticks = <$fh>;
        close $fh;
        foreach my $i (0 .. 1) {
            $populator->insert_to_db({
                ticks  => \@ticks,
                date   => $fill_start->plus_time_interval("${i}d"),
                symbol => 'R_100',
            });
        }

        # Insert frxUSDJPY data ticks
        BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('feed.tick_2012_3', 'frxUSDJPY', '14-Mar-12');

    }
    'Setup ticks';
};

subtest 'ticks_history' => sub {
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if there is no symbol param')
        ->error_message_is('Symbol  invalid.', 'It should return error if there is no symbol param');

    $params->{args}->{ticks_history} = 'wrong';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidSymbol', 'It should return error if there is wrong symbol param')
        ->error_message_is('Symbol wrong invalid.', 'It should return error if there is wrong symbol param');

    $params->{args}->{ticks_history} = 'DFMGI';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('StreamingNotAllowed', 'Streaming not allowed for chartonly contracts.')
        ->error_message_is('Streaming for this symbol is not available due to license restrictions.',
        'It should return error for chartonly contract');

    $params->{args}->{ticks_history} = 'TOP40';
    $params->{args}->{subscribe}     = '1';
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('NoRealtimeQuotes', 'It should return error if realtime quotes not available for this symbol')
        ->error_message_is('Realtime quotes not available for TOP40.', 'It should return error if realtime quotes not available for this symbol');

    set_fixed_time(Date::Utility->new('2016-07-24')->epoch);
    $params->{args}->{ticks_history} = 'frxUSDJPY';
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('MarketIsClosed', 'It should return error if market is closed')
        ->error_message_is('This market is presently closed.', 'It should return error if market is closed');
    set_fixed_time($now->epoch);

    delete $params->{args}->{subscribe};
};

subtest '_validate_start_end' => sub {
    my $start = $now->minus_time_interval('7h');
    my $end   = $start->plus_time_interval('1m');

    $params->{args}->{ticks_history} = 'frxUSDJPY';
    $params->{args}->{end}           = $end->epoch;
    $params->{args}->{start}         = $start->epoch;
    $params->{args}->{style}         = 'ticks';

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{type}, 'history', 'Result type should be history';
    is scalar(@{$result->{data}->{history}->{times}}),  47, 'It should return all ticks between start and end';
    is scalar(@{$result->{data}->{history}->{prices}}), 47, 'It should return all ticks between start and end';

    $params->{args}->{count} = 10;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is scalar(@{$result->{data}->{history}->{times}}), $params->{args}->{count},
        'It should return last 10 ticks if count sent with start and end time';
    is scalar(@{$result->{data}->{history}->{prices}}), $params->{args}->{count},
        'It should return last 10 ticks if count sent with start and end time';
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $end->epoch, 'It should return last 10 ticks if count sent with start and end time';

    $params->{args}->{style} = 'ticks';
    $params->{args}->{end}   = $end->minus_time_interval((365 * 4) . 'd')->epoch;
    $params->{args}->{start} = $start->minus_time_interval((365 * 4) . 'd')->epoch;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $now->epoch, 'It should return latest ticks if client requested ticks older than 3 years';

    $params->{args}->{start} = $now->minus_time_interval('1m')->epoch;
    $params->{args}->{end}   = $end->epoch;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidStartEnd', 'It should return error if start > end time');

    $params->{args}->{start} = $end->epoch;
    $params->{args}->{end}   = $end->epoch;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{$result->{data}->{history}->{times}}, 1, 'It should return one tick when start == end';
    is $result->{data}->{history}->{times}->[0], $end->epoch, 'It should return correct tick when start == end time';

    $params->{args}->{end}   = 'invalid';
    $params->{args}->{count} = 10;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $now->epoch, 'It should return latest ticks for last day if client sent invalid end time';

    $params->{args}->{start} = 'invalid';
    $params->{args}->{end}   = $now->minus_time_interval('6h30m')->epoch;
    $params->{args}->{count} = 2000;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $rpc_ct->result->{data}->{history}->{times}->[0], 1331683200, 'It should return ticks which is 2000 seconds from the end time';

    $params->{args}->{start} = $now->minus_time_interval('1d')->epoch;
    $params->{args}->{end}   = $now->epoch;
    delete $params->{args}->{count};
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{$rpc_ct->result->{data}->{history}->{times}}, MAX_TICK_COUNT, 'It should return ' . MAX_TICK_COUNT . ' ticks by default';

    $params->{args}->{count} = 'invalid';
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{$rpc_ct->result->{data}->{history}->{times}}, MAX_TICK_COUNT, 'It should return ' . MAX_TICK_COUNT . ' ticks if sent invalid count';

    $params->{args}->{count} = MAX_TICK_COUNT + 1;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{$rpc_ct->result->{data}->{history}->{times}}, MAX_TICK_COUNT, 'It should return ' . MAX_TICK_COUNT . ' ticks if sent very big count';

    delete $params->{args}->{start};
    $params->{args}->{count} = 10;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $rpc_ct->result->{data}->{history}->{times}->[0], 1331708391, 'It should start at 10s from now';
    is @{$rpc_ct->result->{data}->{history}->{times}}, 10, 'It should return 10 ticks';

    $params->{args}->{style}       = "candles";
    $params->{args}->{count}       = 4000;
    $params->{args}->{granularity} = 5;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is substr($result->{data}->{candles}->[-3]->{low}, -1), '0', 'Quote with zero at end should be pipsized';
    is @{$result->{data}->{candles}}, 3941, 'It should return 3941 candles (due to missing ticks)';
    is $result->{data}->{candles}->[0]->{epoch}, $now->epoch - (4000 * 5), 'It should start at ' . (4000 * 5) . 's from end';

    $params->{args}->{style}         = 'ticks';
    $params->{args}->{ticks_history} = 'HSI';
    $params->{args}->{start}         = $now->minus_time_interval('1h30m')->epoch;
    $params->{args}->{end}           = $now->plus_time_interval('1d')->epoch;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is substr($rpc_ct->result->{data}->{history}->{prices}->[-5], -1), '0', 'Quote with zero at end should be pipsized';
    is $rpc_ct->result->{data}->{history}->{times}->[-1], $now->epoch - create_underlying('HSI')->delay_amount * 60,
        'It should return last licensed tick for delayed symbol';
    my $ticks_count_without_adjust_time = @{$rpc_ct->result->{data}->{history}->{times}};

    $params->{args}->{adjust_start_time} = 1;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    ok @{$rpc_ct->result->{data}->{history}->{times}} > $ticks_count_without_adjust_time,
        'If sent adjust_start_time param then it should return ticks with shifted start time';

    set_fixed_time($now->plus_time_interval('5h')->epoch);
    my $ul               = create_underlying('HSI');
    my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
    $params->{args}->{end}   = $trading_calendar->closing_on($ul->exchange, $now)->plus_time_interval('1m')->epoch;
    $params->{args}->{start} = $trading_calendar->closing_on($ul->exchange, $now)->minus_time_interval('39m')->epoch;
    delete $params->{args}->{count};
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{data}->{history}->{times}->[0], $trading_calendar->closing_on($ul->exchange, $now)->minus_time_interval('40m')->epoch,
        'If exchange close at end time and sent adjust_start_time then it should shift back start time';
};

subtest 'start/end date boundary checks' => sub {
    # Test - When start is before 3 years
    my $start = time() - (365 * 86400 * 4);    # 4 years from now
    my $end   = $start + (86400 * 2);          # 2 day after start

    my $symbol         = 'frxUSDJPY';
    my $ul             = create_underlying($symbol);
    my $licensed_epoch = $ul->last_licensed_display_epoch;
    my $start_failsafe = $licensed_epoch - 86400;

    $params->{args}                  = {};
    $params->{args}->{start}         = $start;
    $params->{args}->{end}           = $end;
    $params->{args}->{granularity}   = '86400';
    $params->{args}->{count}         = '10000';
    $params->{args}->{ticks_history} = $symbol;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{data}->{candles}->[0]->{epoch}, $start_failsafe, 'When start time is less than 3 years, reset it to licensed epoch - 86400';

    # Test - When end is after now
    $start                   = $now->minus_time_interval('7h');                                                 # 7 hours before now
    $end                     = $now->plus_time_interval('10m');                                                 # 10 minute in future from now
    $params->{args}->{start} = $start->epoch;
    $params->{args}->{end}   = $end->epoch;
    $result                  = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{data}->{candles}->[0]->{epoch} <= $now->epoch, 1, 'When end time is in future, reset it to now';
};

subtest 'history data style' => sub {
    my $start = $now->minus_time_interval('5h');
    my $end   = $start->plus_time_interval('2h');

    $params->{args}                  = {};
    $params->{args}->{ticks_history} = 'HSI';
    $params->{args}->{end}           = $end->epoch;
    $params->{args}->{start}         = $start->epoch;

    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{publish}, 'tick', 'It should return ticks style data by default';

    $params->{args}->{style} = 'invalid';
    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('InvalidStyle', 'It should return error if sent invalid style')
        ->error_message_is('Style invalid invalid', 'It should return error if sent invalid style');

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
    is_deeply [sort keys %{$result->{data}->{candles}->[0]}], [sort qw/ open high epoch low close /];

    $start                           = $now->minus_time_interval('5h');
    $end                             = $start->plus_time_interval('30m');
    $params->{args}                  = {};
    $params->{args}->{ticks_history} = 'HSI';
    $params->{args}->{end}           = $end->epoch;
    $params->{args}->{start}         = $start->epoch;
    $params->{args}->{style}         = 'candles';

    $params->{args}->{granularity} = 60 * 5;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{$rpc_ct->result->{data}->{candles}}, (($end->minute - $start->minute) / 5 + 1),
        'If granularity is 60*5 it should return candles count equals minute difference/5';

    $params->{args}->{granularity} = 60;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{$rpc_ct->result->{data}->{candles}}, ($end->minute - $start->minute + 1),
        'Granularity is 60 by default it should return candles count equals minute difference';
    is $params->{args}->{start}, $result->{data}->{candles}->[0]->{epoch};
    is $params->{args}->{end},   $result->{data}->{candles}->[-1]->{epoch};
    my $first_candle_close = $result->{data}->{candles}->[0]->{close};
    my $end_candle_open    = $result->{data}->{candles}->[-1]->{open};

    $start                   = $start->plus_time_interval('30s');
    $end                     = $end->plus_time_interval('30s');
    $params->{args}->{start} = $start->epoch;
    $params->{args}->{end}   = $end->epoch;
    $result                  = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is $result->{data}->{candles}->[0]->{close}, $first_candle_close, 'It should align candles by close time';
    is $result->{data}->{candles}->[-1]->{open}, $end_candle_open,    'It should align candles by open time';

    $params->{args}->{count} = 1;
    $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    is @{$result->{data}->{candles}}, 1, 'It should return one last candle';
    is $result->{data}->{candles}->[-1]->{open}, $end_candle_open, 'It should return one last candle';
};

done_testing();
