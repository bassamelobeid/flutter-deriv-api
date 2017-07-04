#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 15;
use Test::Warnings 'warning';

use Time::HiRes;
use Cache::RedisDB;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use LandingCompany::Offerings qw(reinitialise_offerings);

initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw(produce_contract make_similar_contract);

my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD'});

#create an empty un-used even so ask_price won't fail preparing market data for pricing engine
#Because the code to prepare market data is called for all pricings in Contract
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'partial_trading',
    {
        type          => 'early_closes',
        recorded_date => Date::Utility->new('2016-01-01'),
        # dummy early close
        calendar => {
            '22-Dec-2016' => {
                '18h00m' => ['FOREX'],
            },
        },
    });

my $bet_params = {
    bet_type   => 'CALL',
    underlying => 'R_100',
    barrier    => 'S0P',
    payout     => 10,
    currency   => 'USD',
    duration   => '5m',
};

subtest 'prices at different times' => sub {
    create_ticks(([100, $now->epoch - 1, 'R_100']));
    my $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
    ok $c->pricing_new,     'pricing new';
    ok !$c->entry_tick, 'entry tick is undefined';
    is $c->barrier->as_absolute + 0, 100, 'barrier is current spot';
    is $c->pricing_spot + 0, 100, 'pricing spot is current spot';
    ok $c->ask_price, 'can price';

    create_ticks(([101, $now->epoch, 'R_100'], [103, $now->epoch + 1, 'R_100']));
    $bet_params->{date_start}   = $now->epoch - 1;
    $bet_params->{date_pricing} = $now->epoch + 61;
    $c                          = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell';
    ok !$c->pricing_new, 'not pricing new';
    ok $c->entry_tick, 'entry tick is defined';
    is $c->entry_tick->quote, 101, 'entry tick is 101';
    is $c->barrier->as_absolute + 0, 101, 'barrier is entry spot';
    is $c->pricing_spot + 0, 103, 'pricing spot is current spot';
    ok $c->bid_price, 'can price';
};

subtest 'entry tick == exit tick' => sub {
    my $contract_duration = 5 * 60;
    create_ticks(([101, $now->epoch - 2, 'R_100'], [103, $now->epoch + $contract_duration, 'R_100']));
    $bet_params->{date_start}   = $now;
    $bet_params->{duration}     = $contract_duration . 's';
    $bet_params->{date_pricing} = $now->epoch + $contract_duration + 1;
    my $c = produce_contract($bet_params);
    ok $c->is_expired, 'contract expired';
    is $c->entry_tick->quote + 0, 103, 'entry tick is 103';
    is $c->exit_tick->quote + 0,  103, 'entry tick is 103';
    ok !$c->is_valid_to_sell, 'not valid to sell';
    like($c->primary_validation_error->message, qr/only one tick throughout contract period/, 'throws error');
};

subtest 'entry tick before contract start (only forward starting contracts)' => sub {
    my $contract_duration = 5 * 60;
    create_ticks(([101, $now->epoch - 2, 'R_100'], [103, $now->epoch + $contract_duration, 'R_100']));
    $bet_params->{date_start}                 = $now;
    $bet_params->{duration}                   = $contract_duration . 's';
    $bet_params->{is_forward_starting}        = 1;
    $bet_params->{starts_as_forward_starting} = 1;
    $bet_params->{date_pricing}               = $now->epoch + $contract_duration + 1;
    my $c = produce_contract($bet_params);
    ok $c->is_expired, 'contract expired';
    is $c->entry_tick->quote + 0, 101, 'entry tick is 101';
    is $c->exit_tick->quote + 0,  103, 'exit tick is 103';
    ok $c->is_valid_to_sell, 'valid to sell';
};

subtest 'waiting for entry tick' => sub {
    create_ticks();
    $bet_params->{date_start}   = $now;
    $bet_params->{date_pricing} = $now->epoch + 1;
    $bet_params->{duration}     = '1h';
    delete $bet_params->{is_forward_starting};
    delete $bet_params->{starts_as_forward_starting};
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'not valid to sell';
    like($c->primary_validation_error->message, qr/Waiting for entry tick/, 'throws error');
    create_ticks([101, $now->epoch + 1, 'R_100']);
    $c = produce_contract($bet_params);
    ok $c->entry_tick,       'entry tick defined';
    ok $c->is_valid_to_sell, 'valid to sell';
    $bet_params->{date_pricing} = $now->epoch + 302;    # 1 second too far
    $c = produce_contract($bet_params);
    ok !$c->is_expired, 'not expired';
    my $is_valid;
    like(warning { $is_valid = $c->is_valid_to_sell }, qr/Quote too old/, 'get warnings');
    ok !$is_valid, 'not valid to sell';
    like($c->primary_validation_error->message, qr/Quote too old/, 'throws error');
    $bet_params->{date_pricing} = $now->epoch + 301;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell once you have a close enough tick';
};

subtest 'tick expiry contract settlement' => sub {
    create_ticks([100, $now->epoch - 1, 'R_100'], [101, $now->epoch + 1, 'R_100']);
    $bet_params->{date_start}   = $now;
    $bet_params->{date_pricing} = $now->epoch + 299;
    $bet_params->{duration}     = '5t';
    my $c = produce_contract($bet_params);
    ok $c->tick_expiry, 'tick expiry contract';
    ok !$c->is_expired,          'not expired';
    ok !$c->exit_tick,           'no exit tick';
    ok !$c->is_after_expiry,     'not after expiry';
    ok !$c->is_after_settlement, 'not after settlement';
    ok !$c->is_valid_to_sell,    'not valid to sell';
    like($c->primary_validation_error->message, qr/resale of tick expiry contract/, 'throws error');

    $bet_params->{date_pricing} = $now->epoch + 301;
    $c = produce_contract($bet_params);
    ok $c->tick_expiry, 'tick expiry contract';
    ok !$c->is_expired, 'not expired';
    ok !$c->exit_tick,  'no exit tick';
    ok $c->is_after_expiry,     'is after expiry';
    ok $c->is_after_settlement, 'is after settlement';
    ok !$c->is_valid_to_sell, 'not valid to sell';
    like($c->primary_validation_error->message, qr/exit tick undefined after 5 minutes of contract start/, 'throws error');

    create_ticks(
        [100, $now->epoch - 1,   'R_100'],
        [101, $now->epoch + 1,   'R_100'],
        [101, $now->epoch + 2,   'R_100'],
        [102, $now->epoch + 3,   'R_100'],
        [104, $now->epoch + 4,   'R_100'],
        [102, $now->epoch + 5,   'R_100'],
        [102, $now->epoch + 299, 'R_100']);
    $bet_params->{date_pricing} = $now->epoch + 299;
    $c = produce_contract($bet_params);
    ok $c->tick_expiry,         'tick expiry contract';
    ok $c->is_expired,          'expired';
    ok $c->is_after_expiry,     'is after expiry';
    ok $c->is_after_settlement, 'is after settlement';
    ok $c->exit_tick,           'has exit tick';
    ok $c->is_valid_to_sell,    'valid to sell';
};

subtest 'intraday duration contract settlement' => sub {
    delete $bet_params->{is_forward_starting};
    create_ticks([101, $now->epoch - 1, 'R_100'], [102, $now->epoch + 301, 'R_100'], [103, $now->epoch + 302, 'R_100']);
    $bet_params->{date_start}   = $now;
    $bet_params->{duration}     = '5m';
    $bet_params->{date_pricing} = $now->epoch + 301;
    my $c = produce_contract($bet_params);
    ok $c->is_expired, 'is expired';
    ok !$c->is_valid_to_sell, 'not valid to sell';
    ok $c->missing_market_data, 'missing market data if entry tick is undef after expiry';
    like($c->primary_validation_error->message, qr/entry tick is after exit tick/, 'throws error');

    create_ticks([101, $now->epoch + 1, 'R_100'], [102, $now->epoch + 301, 'R_100']);
    $bet_params->{date_start}   = $now;
    $bet_params->{duration}     = '5m';
    $bet_params->{date_pricing} = $now->epoch + 301;
    $c                          = produce_contract($bet_params);
    ok $c->is_expired, 'is expired';
    ok !$c->is_valid_to_sell, 'not valid to sell';
    ok $c->missing_market_data, 'missing market data if entry tick is undef after expiry';
    like($c->primary_validation_error->message, qr/only one tick throughout contract period/, 'throws error');

    create_ticks([100, $now->epoch - 1, 'R_100']);
    $c = produce_contract($bet_params);
    ok $c->is_after_settlement, 'after expiry';
    ok !$c->entry_tick,       'no entry tick';
    ok !$c->is_valid_to_sell, 'not valid to sell';
    ok $c->missing_market_data, 'missing market data if entry tick is undef after expiry';
    like($c->primary_validation_error->message, qr/entry tick is undefined/, 'throws error');

    create_ticks([101, $now->epoch + 1, 'R_100']);
    $c = produce_contract($bet_params);
    ok $c->is_after_expiry, 'after expiry';
    ok $c->is_expired,      'it is expireable';
    ok !$c->is_settleable, 'it is not settleable as no exit tick';
    ok $c->is_after_settlement, 'after settlement';
    ok $c->exit_tick,           'there is exit tick';
    ok !$c->is_valid_to_sell,    'not valid to sell';
    ok !$c->missing_market_data, 'no missing market data while waiting for exit tick after expiry';
    like($c->primary_validation_error->message, qr/exit tick is undefined/, 'throws error');
};

subtest 'longcode misbehaving for daily contracts' => sub {
    $bet_params->{duration} = '2d';
    my $c = produce_contract($bet_params);
    ok $c->expiry_daily, 'multiday contract';
    is $c->expiry_type,  'daily';
    my $expiry_daily_longcode = $c->longcode;
    $bet_params->{date_pricing} = $c->date_start->plus_time_interval('2d');
    $c = produce_contract($bet_params);
    is $c->expiry_type, 'intraday';
    ok $c->is_intraday, 'date_pricing reaches intraday';
    is_deeply($c->longcode, $expiry_daily_longcode, 'longcode does not change');
};

subtest 'longcode of daily contracts crossing Thursday 21GMT expiring on Friday' => sub {
    create_ticks([166.26, 1463020000, 'frxGBPUSD'], [166.27, 1463087154, 'frxGBPUSD']);
    my $c = produce_contract('PUT_FRXGBPUSD_166.27_1463087154_1463173200_S0P_0', 'USD');
    my $c2 = make_similar_contract($c, {date_pricing => $c->date_start});
    ok $c2->expiry_daily, 'multiday contract';
    is_deeply($c2->longcode,
        ['Win payout if [_3] is strictly lower than [_6] at [_5].', 'USD', '166.27', 'GBP/USD', [], ['close on [_1]', '2016-05-13'], ['entry spot']]);
    diag("after again");
    is $c->expiry_type, 'daily';
    my $expiry_daily_longcode = $c2->longcode;
    $c2 = make_similar_contract($c, {date_pricing => $c->date_start->plus_time_interval('5h')});
    ok $c2->is_intraday, 'date_pricing reaches intraday';
    is_deeply($c2->longcode, $expiry_daily_longcode, 'longcode does not change');
    is $c->expiry_type, 'daily';

};

subtest 'longcode of daily contracts at 10 minutes before friday close' => sub {
    my $c = produce_contract('PUT_FRXGBPUSD_166.27_1463172600_1463173200_S0P_0', 'usd');
    my $c2 = make_similar_contract($c, {date_pricing => $c->date_start});
    is_deeply(
        $c2->longcode,
        [
            'Win payout if [_3] is strictly lower than [_6] at [_5] after [_4].',
            'usd', '166.27', 'GBP/USD', ['contract start time'], ['10 minutes'], ['entry spot']]);
    is $c2->expiry_type, 'intraday';
    ok $c2->is_intraday, 'is an intraday contract';
};

subtest 'longcode of 22 hours contract from Thursday 3GMT' => sub {
    my $c = produce_contract('PUT_FRXGBPUSD_166.27_1463022000_1463101200_S0P_0', 'usd');
    my $c2 = make_similar_contract($c, {date_pricing => $c->date_start});
    is_deeply(
        $c2->longcode,
        [
            'Win payout if [_3] is strictly lower than [_6] at [_5] after [_4].',
            'usd', '166.27', 'GBP/USD', ['contract start time'], ['22 hours'], ['entry spot']]);
    is $c2->expiry_type, 'intraday';
    ok $c2->is_intraday, 'is an intraday contract';
};

subtest 'longcode of index daily contracts' => sub {
    create_ticks([166.27, 1469523600, 'GDAXI']);
    my $c = produce_contract('PUT_GDAXI_166.27_1469523600_1469633400_S0P_0', 'USD');
    my $c2 = make_similar_contract($c, {date_pricing => $c->date_start});
    ok $c2->expiry_daily, 'is daily contract';
    is_deeply(
        $c2->longcode,
        [
            'Win payout if [_3] is strictly lower than [_6] at [_5].',
            'USD', '166.27', 'German Index', [], ['close on [_1]', '2016-07-27'],
            ['entry spot']]);
    is $c->expiry_type, 'daily';
    my $expiry_daily_longcode = $c2->longcode;
    $c2 = make_similar_contract($c, {date_pricing => $c->date_start->plus_time_interval('8h')});
    ok $c2->expiry_daily, 'is daily contract';
    is_deeply($c2->longcode, $expiry_daily_longcode, 'longcode does not change');
    is $c->expiry_type, 'daily';
    $c2 = make_similar_contract($c, {date_pricing => $c->date_start->plus_time_interval('24h')});
    ok $c2->is_intraday, 'date_pricing reaches intraday';
    is_deeply($c2->longcode, $expiry_daily_longcode, 'longcode does not change');
    is $c->expiry_type, 'daily';
};

subtest 'longcode of daily contract on early close day' => sub {
    create_ticks([166.27, 1482332400, 'frxGBPUSD'], [166.27, 1482429600, 'frxGBPUSD']);
    my $c = produce_contract('PUT_FRXGBPUSD_166.27_1482332400_1482429600_S0P_0', 'USD');
    my $c2 = make_similar_contract($c, {date_pricing => $c->date_start});
    ok $c2->expiry_daily, 'is a multiday contract';
    is_deeply($c2->longcode,
        ['Win payout if [_3] is strictly lower than [_6] at [_5].', 'USD', '166.27', 'GBP/USD', [], ['close on [_1]', '2016-12-22'], ['entry spot']]);
    is $c2->expiry_type, 'daily';
};

subtest 'longcode of intraday contracts' => sub {
    create_ticks([166.27, 1463126400, 'frxGBPUSD'], [166.27, 1463173200, 'frxGBPUSD']);
    my $c = produce_contract('PUT_FRXGBPUSD_166.27_1463126400_1463173200_S0P_0', 'USD');
    my $c2 = make_similar_contract($c, {date_pricing => $c->date_start});
    ok $c2->is_intraday, 'is an contract';
    is_deeply(
        $c2->longcode,
        [
            'Win payout if [_3] is strictly lower than [_6] at [_5] after [_4].',
            'USD', '166.27', 'GBP/USD', ['contract start time'], ['13 hours'], ['entry spot']]);
};

subtest 'ATM and non ATM switches on sellback' => sub {
    my $now = Date::Utility->new;
    create_ticks([101, $now->epoch, 'R_100'], [100, $now->epoch + 1, 'R_100'], [100.1, $now->epoch + 2, 'R_100'], [100, $now->epoch + 3, 'R_100']);
    $bet_params->{duration}     = '15m';
    $bet_params->{date_start}   = $now;
    $bet_params->{date_pricing} = $now->epoch + 2;
    $bet_params->{barrier}      = 'S10P';
    my $c = produce_contract($bet_params);
    is $c->current_spot + 0, 100.1, 'current tick is 100.1';
    is $c->barrier->as_absolute + 0, 100.1, 'barrier is 100.1';
    ok !$c->is_atm_bet, 'not atm bet';
    #starts atm
    $bet_params->{barrier}      = 'S0P';
    $bet_params->{date_pricing} = $now->epoch + 3;
    $c                          = produce_contract($bet_params);
    ok $c->is_atm_bet, 'atm contract';
    ok $c->opposite_contract_for_sale->supplied_barrier == $c->entry_spot, 'opposite barrier correctly set';
    ok $c->opposite_contract_for_sale->barrier->as_absolute == $c->opposite_contract_for_sale->current_spot, 'barrier identical to spot';
    ok !$c->opposite_contract_for_sale->is_atm_bet, 'non atm bet';
};

sub create_ticks {
    my @ticks = @_;

    Cache::RedisDB->flushall;
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;

    for my $tick (@ticks) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            quote      => $tick->[0],
            epoch      => $tick->[1],
            underlying => $tick->[2],
        });
    }
    reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
    Time::HiRes::sleep(0.1);

    return;
}
