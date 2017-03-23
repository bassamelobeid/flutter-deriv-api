#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::FailWarnings;
use BOM::Product::ContractFactory qw(produce_batch_contract produce_contract);

use Postgres::FeedDB::Spot::Tick;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use Date::Utility;

my $now = Date::Utility->new('2017-03-15');
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
    like($ask_prices->{RANGE}->{'100.200-99.800'}->{error}{message_to_client},    qr/not offered for this duration/, 'throws an error for invalid duration');
    like($ask_prices->{UPORDOWN}->{'100.200-99.800'}->{error}{message_to_client}, qr/not offered for this duration/, 'throws an error for invalid duration');
    like($ask_prices->{RANGE}->{'100.250-98.750'}->{error}{message_to_client},    qr/not offered for this duration/, 'throws an error for invalid duration');
    like($ask_prices->{UPORDOWN}->{'100.250-98.750'}->{error}{message_to_client}, qr/not offered for this duration/, 'throws an error for invalid duration');

    $args->{duration} = '1d';
    $batch            = produce_batch_contract($args);
    $ask_prices       = $batch->ask_prices;
    is $ask_prices->{RANGE}->{'100.200-99.800'}->{ask_price}, 0.5, 'minimum ask price';
    like($ask_prices->{UPORDOWN}->{'100.200-99.800'}->{error}{message_to_client}, qr/This contract offers no return/, 'throws an error for invalid duration');
    is $ask_prices->{RANGE}->{'100.250-98.750'}->{ask_price},    2.65, 'correct ask price';
    is $ask_prices->{UPORDOWN}->{'100.250-98.750'}->{ask_price}, 8.12, 'correct ask price';

    $args->{bet_types} = ['CALL', 'RANGE'];
    $batch = produce_batch_contract($args);
    throws_ok { $batch->ask_prices } qr/Could not mixed single barrier and double barrier contracts/, 'throws error if bet_type mismatch';

    $args->{bet_types} = ['CALL', 'ONETOUCH'];
    $args->{barriers} = [
        100.12,
        {
            barrier  => 100.12,
            barrier2 => 99.20
        }];
    $batch = produce_batch_contract($args);
    throws_ok { $batch->ask_prices } qr/Invalid barrier list\. Single barrier input is expected\./, 'throws error if bet_type-barrier mismatch';
    $args->{bet_types} = ['RANGE', 'EXPIRYRANGE'];
    $batch = produce_batch_contract($args);
    throws_ok { $batch->ask_prices } qr/Invalid barrier list\. Double barrier input is expected\./, 'throws error if bet_type-barrier mismatch';
};

done_testing();
