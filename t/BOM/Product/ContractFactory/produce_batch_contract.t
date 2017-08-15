#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Warnings;
use BOM::Product::ContractFactory qw(produce_batch_contract produce_contract);
use Try::Tiny;

use Test::MockModule;
use Postgres::FeedDB::Spot::Tick;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use Date::Utility;
use JSON qw(to_json);

my $mocked_decimate = Test::MockModule->new('BOM::Market::DataDecimate');
$mocked_decimate->mock('get', sub {[map {{epoch => $_, decimate_epoch => $_, quote => 100 + rand(1e-9)}} (0..80)]});
my %custom_otm =
    map { rand(1234) => {conditions => {market => $_, expiry_type => 'daily', is_atm_bet => 0}, value => 0.2,} } qw(forex indices commodities stocks);
BOM::Platform::Runtime->instance->app_config->quants->custom_otm_threshold(to_json(\%custom_otm));

my $now = Date::Utility->new('2017-03-15');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('economic_events', {recorded_date => $now});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) foreach qw(USD JPY JPY-USD);

my $fake_tick = Postgres::FeedDB::Spot::Tick->new({
    underlying => 'frxUSDJPY',
    quote      => 100,
    epoch      => $now->epoch,
});

subtest 'produce_batch_contract - price check' => sub {
    my $args = {
        bet_types    => ['CALL', 'PUT'],
        underlying   => 'frxUSDJPY',
        barrier      => 'S20P',
        date_start   => $now,
        date_pricing => $now,
        duration     => '1h',
        currency     => 'USD',
        payout       => 10,
        current_tick => $fake_tick,
    };

    lives_ok {
        my $batch      = produce_batch_contract($args);
        my $ask_prices = $batch->ask_prices;
        delete $args->{bet_types};
        my $call = produce_contract({%$args, bet_type => 'CALL'})->ask_price;
        my $put  = produce_contract({%$args, bet_type => 'PUT'})->ask_price;
        is $ask_prices->{CALL}->{'100.020'}->{ask_price}, $call, 'same call price';
        is $ask_prices->{PUT}->{'100.020'}->{ask_price},  $put,  'same put price';
    }
    'ask_prices';

    lives_ok {
        $args->{bet_types} = ['CALL', 'PUT'];
        $args->{barriers}  = ['S20P', 'S15P'];
        delete $args->{barrier};
        my $batch      = produce_batch_contract($args);
        my $ask_prices = $batch->ask_prices;
        delete $args->{bet_types};
        delete $args->{barriers};
        my $call1 = produce_contract({
                %$args,
                bet_type => 'CALL',
                barrier  => 'S20P'
            })->ask_price;
        my $call2 = produce_contract({
                %$args,
                bet_type => 'CALL',
                barrier  => 'S15P'
            })->ask_price;
        my $put1 = produce_contract({
                %$args,
                bet_type => 'PUT',
                barrier  => 'S20P'
            })->ask_price;
        my $put2 = produce_contract({
                %$args,
                bet_type => 'PUT',
                barrier  => 'S15P'
            })->ask_price;
        is $ask_prices->{CALL}->{'100.020'}->{ask_price}, $call1, 'same call price';
        is $ask_prices->{PUT}->{'100.020'}->{ask_price},  $put1,  'same put price';
        is $ask_prices->{CALL}->{'100.015'}->{ask_price}, $call2, 'same call price';
        is $ask_prices->{PUT}->{'100.015'}->{ask_price},  $put2,  'same put price';
    }
    'ask_prices';
};

subtest 'produce_batch_contract - error check' => sub {
    my $args = {
        bet_types  => ['RANGE', 'UPORDOWN'],
        underlying => 'frxUSDJPY',
        barriers   => [{
                barrier  => 100.2,
                barrier2 => 99.8
            },
            {
                barrier  => 100.25,
                barrier2 => 98.75
            }
        ],
        date_start   => $now,
        date_pricing => $now,
        duration     => '1h',
        currency     => 'USD',
        payout       => 10,
        current_tick => $fake_tick,
    };

    my $batch      = produce_batch_contract($args);
    my $ask_prices = $batch->ask_prices;
    is_deeply($ask_prices->{RANGE}->{'100.200-99.800'}->{error}{message_to_client},    ['Trading is not offered for this duration.'],);
    is_deeply($ask_prices->{UPORDOWN}->{'100.200-99.800'}->{error}{message_to_client}, ['Trading is not offered for this duration.'],);
    is_deeply($ask_prices->{RANGE}->{'100.250-98.750'}->{error}{message_to_client},    ['Trading is not offered for this duration.'],);
    is_deeply($ask_prices->{UPORDOWN}->{'100.250-98.750'}->{error}{message_to_client}, ['Trading is not offered for this duration.'],);

    $args->{duration} = '1d';
    $batch            = produce_batch_contract($args);
    $ask_prices       = $batch->ask_prices;
    cmp_ok $ask_prices->{RANGE}->{'100.200-99.800'}->{ask_price}, '==', 2, 'minimum ask price';
    is_deeply($ask_prices->{UPORDOWN}->{'100.200-99.800'}->{error}{message_to_client}, ['This contract offers no return.'],);
    is $ask_prices->{RANGE}->{'100.250-98.750'}->{ask_price},    2.34, 'correct ask price';
    is $ask_prices->{UPORDOWN}->{'100.250-98.750'}->{ask_price}, 8.39, 'correct ask price';

    $args->{bet_types} = ['CALL', 'RANGE'];
    try {
        $batch = produce_batch_contract($args);
        $batch->ask_prices;
    } catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid barrier. ([_1])';
        like $_->message_to_client->[1], qr/Could not mixed single barrier and double barrier contracts/, 'correct error args';
    };

    $args->{bet_types} = ['CALL', 'ONETOUCH'];
    $args->{barriers} = [
        100.12,
        {
            barrier  => 100.12,
            barrier2 => 99.20
        }];
    try {
        $batch = produce_batch_contract($args);
        $batch->ask_prices;
    } catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid barrier. ([_1])';
        like $_->message_to_client->[1], qr/Single barrier input is expected/, 'correct error args';
    };
    $args->{bet_types} = ['RANGE', 'EXPIRYRANGE'];
    try {
        $batch = produce_batch_contract($args);
        throws_ok { $batch->ask_prices } qr/BOM::Product::Exception/, 'throws error if bet_type-barrier mismatch';
    } catch {
        isa_ok $_, 'BOM::Product::Exception';
        is $_->message_to_client->[0], 'Invalid barrier. ([_1])';
        like $_->message_to_client->[1], qr/Double barrier input is expected/, 'correct error args';
    };
};

done_testing();
