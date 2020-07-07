#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Warnings;

use BOM::Product::ContractFactory qw( produce_contract );
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

my $now = Date::Utility->new('2016-05-11 01:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(frxUSDJPY frxAUDJPY frxAUDUSD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(AUD JPY USD AUD-JPY);

subtest 'sanity check' => sub {
    my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDJPY',
        epoch      => $now->epoch,
        quote      => 80.53,
    });

    my %barriers = (
        1 => {
            high_barrier => 81,
            low_barrier  => 79
        },
        2 => {
            high_barrier => 81,
            low_barrier  => 79
        },
        5 => {
            high_barrier => 84,
            low_barrier  => 77.8
        },
    );
    foreach my $duration (1, 2, 5) {
        my $c = produce_contract({
            bet_type     => 'RANGE',
            underlying   => 'frxAUDJPY',
            date_start   => $now,
            date_pricing => $now,
            duration     => $duration . 'd',
            currency     => 'USD',
            payout       => 10,
            current_tick => $current_tick,
            %{$barriers{$duration}},
        });
        ok $c->theo_probability->amount > 0.4, 'theo is higher than 40%';
        ok $c->theo_probability->amount < 0.6, 'theo is lower than 60%';
    }
};

subtest 'no_floor_for_bid_probability' => sub {
    my $mock_pc = Test::MockModule->new('Price::Calculator');
    $mock_pc->mock(
        'theo_probability',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'theo_probability',
                description => 'fake theo prob',
                set_by      => 'Price::Calculator',
                base_amount => 0.03
            });
        });
    $mock_pc->mock(
        'commission_markup',
        sub {
            return Math::Util::CalculatedValue::Validatable->new({
                name        => 'commission_markup',
                description => 'fake commission markup',
                set_by      => 'Price::Calculator',
                base_amount => 0.01,
            });
        });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => 1404986402,
        quote      => 100
    });
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => 1404986404,
        quote      => 103
    });
    my $bet_params = {
        barrier      => "+2.02",
        bet_type     => "ONETOUCH",
        currency     => "USD",
        date_pricing => 1404986404,
        date_start   => 1404986400,
        duration     => "5t",
        payout       => 100,
        underlying   => "R_100",
    };

    my $bet = produce_contract($bet_params);
    is $bet->bid_probability->amount, 0.02;
};

