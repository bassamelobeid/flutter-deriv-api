#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::NoWarnings;

use Time::HiRes;
use Cache::RedisDB;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

use BOM::Product::ContractFactory qw(produce_contract);

my $now = Date::Utility->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD'});

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
    $bet_params->{date_start}          = $now;
    $bet_params->{duration}            = $contract_duration . 's';
    $bet_params->{is_forward_starting} = 1;
    $bet_params->{date_pricing}        = $now->epoch + $contract_duration + 1;
    my $c = produce_contract($bet_params);
    ok $c->is_expired, 'contract expired';
    is $c->entry_tick->quote + 0, 101, 'entry tick is 101';
    is $c->exit_tick->quote + 0,  103, 'exit tick is 103';
    ok $c->is_valid_to_sell, 'valid to sell';
};

subtest 'waiting for entry tick' => sub {
    create_ticks();
    $bet_params->{date_start}          = $now;
    $bet_params->{date_pricing}        = $now->epoch + 1;
    $bet_params->{duration}            = '1h';
    $bet_params->{is_forward_starting} = 1;
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_sell, 'not valid to sell';
    like($c->primary_validation_error->message, qr/Waiting for entry tick/, 'throws error');
    create_ticks([101, $now->epoch, 'R_100']);
    $c = produce_contract($bet_params);
    ok $c->entry_tick,       'entry tick defined';
    ok $c->is_valid_to_sell, 'valid to sell';
    $bet_params->{date_pricing} = $now->epoch + 301;    # 1 second too far
    $c = produce_contract($bet_params);
    ok !$c->is_expired,       'not expired';
    ok !$c->is_valid_to_sell, 'not valid to sell';
    like($c->primary_validation_error->message, qr/Quote too old/, 'throws error');
    create_ticks([101, $now->epoch + 1, 'R_100']);
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_sell, 'valid to sell once you have a close enough tick';
};

subtest 'tick expiry contract settlement' => sub {
    create_ticks([100, $now->epoch - 1, 'R_100'],[101, $now->epoch + 1, 'R_100']);
    $bet_params->{date_start} = $now;
    $bet_params->{date_pricing} = $now->epoch + 299;
    $bet_params->{duration} = '5t';
    my $c = produce_contract($bet_params);
    ok $c->tick_expiry, 'tick expiry contract';
    ok !$c->is_expired, 'not expired';
    ok !$c->exit_tick, 'no exit tick';
    ok !$c->is_after_expiry, 'not after expiry';
    ok !$c->is_valid_to_sell, 'not valid to sell';
    like ($c->primary_validation_error->message, qr/resale of tick expiry contract/, 'throws error');

    $bet_params->{date_pricing} = $now->epoch + 301;
    $c = produce_contract($bet_params);
    ok $c->tick_expiry, 'tick expiry contract';
    ok !$c->is_expired, 'not expired';
    ok !$c->exit_tick, 'no exit tick';
    ok $c->is_after_expiry, 'is after expiry';
    ok !$c->is_valid_to_sell, 'not valid to sell';
    like ($c->primary_validation_error->message, qr/exit tick is undefined after max allowed time for tick/, 'throws error');

    create_ticks([100, $now->epoch - 1, 'R_100'],[101, $now->epoch + 1, 'R_100'],[101, $now->epoch + 2, 'R_100'],[102, $now->epoch + 3, 'R_100'],[104, $now->epoch + 4, 'R_100'],[102, $now->epoch + 5, 'R_100'],[102, $now->epoch + 299, 'R_100']);
    $bet_params->{date_pricing} = $now->epoch + 299;
    $c = produce_contract($bet_params);
    ok $c->tick_expiry, 'tick expiry contract';
    ok $c->is_expired, 'expired';
    ok $c->exit_tick, 'has exit tick';
    ok $c->is_valid_to_sell, 'valid to sell';
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
    Time::HiRes::sleep(0.1);

    return;
}
