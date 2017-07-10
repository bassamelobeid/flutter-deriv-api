#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 2;
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
