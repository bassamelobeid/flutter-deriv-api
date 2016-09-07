#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use Format::Util::Numbers qw/roundnear/;

use BOM::MarketData::VolSurface::Empirical;
use BOM::Market::Underlying;
use BOM::Market::AggTicks;
use Date::Utility;

# last tick time
my $now   = Date::Utility->new(1446194860);
my $ticks = [{
        'agg_epoch'  => 1446193965,
        'ask'        => 120.772,
        'bid'        => 120.763,
        'count'      => 15,
        'epoch'      => 1446193965,
        'quote'      => 120.768,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446193980,
        'ask'        => 120.754,
        'bid'        => 120.751,
        'count'      => 14,
        'epoch'      => 1446193980,
        'quote'      => 120.752,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446193995,
        'ask'        => 120.769,
        'bid'        => 120.743,
        'count'      => 15,
        'epoch'      => 1446193995,
        'quote'      => 120.756,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194010,
        'ask'        => 120.759,
        'bid'        => 120.754,
        'count'      => 14,
        'epoch'      => 1446194010,
        'quote'      => 120.757,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194025,
        'ask'        => 120.759,
        'bid'        => 120.749,
        'count'      => 11,
        'epoch'      => 1446194025,
        'quote'      => 120.754,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194040,
        'ask'        => 120.743,
        'bid'        => 120.739,
        'count'      => 15,
        'epoch'      => 1446194040,
        'quote'      => 120.741,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194055,
        'ask'        => 120.764,
        'bid'        => 120.74,
        'count'      => 15,
        'epoch'      => 1446194055,
        'quote'      => 120.752,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194070,
        'ask'        => 120.773,
        'bid'        => 120.757,
        'count'      => 15,
        'epoch'      => 1446194070,
        'quote'      => 120.765,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194085,
        'ask'        => 120.763,
        'bid'        => 120.76,
        'count'      => 15,
        'epoch'      => 1446194085,
        'quote'      => 120.762,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194100,
        'ask'        => 120.786,
        'bid'        => 120.76,
        'count'      => 15,
        'epoch'      => 1446194100,
        'quote'      => 120.773,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194115,
        'ask'        => 120.78,
        'bid'        => 120.771,
        'count'      => 15,
        'epoch'      => 1446194115,
        'quote'      => 120.775,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194130,
        'ask'        => 120.79,
        'bid'        => 120.781,
        'count'      => 15,
        'epoch'      => 1446194130,
        'quote'      => 120.786,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194145,
        'ask'        => 120.791,
        'bid'        => 120.789,
        'count'      => 15,
        'epoch'      => 1446194145,
        'quote'      => 120.790,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194160,
        'ask'        => 120.791,
        'bid'        => 120.765,
        'count'      => 14,
        'epoch'      => 1446194160,
        'quote'      => 120.778,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194175,
        'ask'        => 120.787,
        'bid'        => 120.778,
        'count'      => 15,
        'epoch'      => 1446194175,
        'quote'      => 120.782,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194190,
        'ask'        => 120.777,
        'bid'        => 120.769,
        'count'      => 15,
        'epoch'      => 1446194190,
        'quote'      => 120.773,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194205,
        'ask'        => 120.754,
        'bid'        => 120.744,
        'count'      => 15,
        'epoch'      => 1446194205,
        'quote'      => 120.749,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194220,
        'ask'        => 120.773,
        'bid'        => 120.766,
        'count'      => 15,
        'epoch'      => 1446194220,
        'quote'      => 120.769,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194235,
        'ask'        => 120.769,
        'bid'        => 120.763,
        'count'      => 15,
        'epoch'      => 1446194235,
        'quote'      => 120.766,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194250,
        'ask'        => 120.769,
        'bid'        => 120.766,
        'count'      => 15,
        'epoch'      => 1446194250,
        'quote'      => 120.768,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194265,
        'ask'        => 120.763,
        'bid'        => 120.753,
        'count'      => 15,
        'epoch'      => 1446194265,
        'quote'      => 120.758,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194280,
        'ask'        => 120.766,
        'bid'        => 120.739,
        'count'      => 14,
        'epoch'      => 1446194280,
        'quote'      => 120.752,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194295,
        'ask'        => 120.753,
        'bid'        => 120.744,
        'count'      => 14,
        'epoch'      => 1446194295,
        'quote'      => 120.749,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194310,
        'ask'        => 120.742,
        'bid'        => 120.723,
        'count'      => 15,
        'epoch'      => 1446194310,
        'quote'      => 120.733,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194325,
        'ask'        => 120.748,
        'bid'        => 120.721,
        'count'      => 15,
        'epoch'      => 1446194325,
        'quote'      => 120.734,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194340,
        'ask'        => 120.75,
        'bid'        => 120.74,
        'count'      => 15,
        'epoch'      => 1446194340,
        'quote'      => 120.745,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194355,
        'ask'        => 120.748,
        'bid'        => 120.745,
        'count'      => 15,
        'epoch'      => 1446194355,
        'quote'      => 120.746,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194370,
        'ask'        => 120.743,
        'bid'        => 120.731,
        'count'      => 14,
        'epoch'      => 1446194370,
        'quote'      => 120.737,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194385,
        'ask'        => 120.739,
        'bid'        => 120.736,
        'count'      => 15,
        'epoch'      => 1446194385,
        'quote'      => 120.738,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194400,
        'ask'        => 120.743,
        'bid'        => 120.731,
        'count'      => 15,
        'epoch'      => 1446194400,
        'quote'      => 120.737,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194415,
        'ask'        => 120.74,
        'bid'        => 120.732,
        'count'      => 15,
        'epoch'      => 1446194415,
        'quote'      => 120.736,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194430,
        'ask'        => 120.743,
        'bid'        => 120.735,
        'count'      => 15,
        'epoch'      => 1446194430,
        'quote'      => 120.739,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194445,
        'ask'        => 120.749,
        'bid'        => 120.741,
        'count'      => 14,
        'epoch'      => 1446194445,
        'quote'      => 120.745,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194460,
        'ask'        => 120.753,
        'bid'        => 120.751,
        'count'      => 14,
        'epoch'      => 1446194460,
        'quote'      => 120.752,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194475,
        'ask'        => 120.76,
        'bid'        => 120.757,
        'count'      => 15,
        'epoch'      => 1446194475,
        'quote'      => 120.758,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194490,
        'ask'        => 120.773,
        'bid'        => 120.748,
        'count'      => 11,
        'epoch'      => 1446194490,
        'quote'      => 120.761,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194505,
        'ask'        => 120.737,
        'bid'        => 120.729,
        'count'      => 13,
        'epoch'      => 1446194505,
        'quote'      => 120.733,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194520,
        'ask'        => 120.729,
        'bid'        => 120.721,
        'count'      => 13,
        'epoch'      => 1446194520,
        'quote'      => 120.725,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194535,
        'ask'        => 120.695,
        'bid'        => 120.695,
        'count'      => 15,
        'epoch'      => 1446194535,
        'quote'      => 120.695,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194550,
        'ask'        => 120.69,
        'bid'        => 120.685,
        'count'      => 14,
        'epoch'      => 1446194550,
        'quote'      => 120.688,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194565,
        'ask'        => 120.728,
        'bid'        => 120.678,
        'count'      => 15,
        'epoch'      => 1446194565,
        'quote'      => 120.703,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194580,
        'ask'        => 120.709,
        'bid'        => 120.705,
        'count'      => 15,
        'epoch'      => 1446194580,
        'quote'      => 120.707,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194595,
        'ask'        => 120.716,
        'bid'        => 120.713,
        'count'      => 15,
        'epoch'      => 1446194595,
        'quote'      => 120.714,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194610,
        'ask'        => 120.708,
        'bid'        => 120.698,
        'count'      => 15,
        'epoch'      => 1446194610,
        'quote'      => 120.703,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194625,
        'ask'        => 120.694,
        'bid'        => 120.692,
        'count'      => 15,
        'epoch'      => 1446194625,
        'quote'      => 120.693,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194640,
        'ask'        => 120.673,
        'bid'        => 120.671,
        'count'      => 15,
        'epoch'      => 1446194640,
        'quote'      => 120.672,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194655,
        'ask'        => 120.685,
        'bid'        => 120.682,
        'count'      => 15,
        'epoch'      => 1446194655,
        'quote'      => 120.684,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194670,
        'ask'        => 120.685,
        'bid'        => 120.669,
        'count'      => 15,
        'epoch'      => 1446194670,
        'quote'      => 120.677,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194685,
        'ask'        => 120.688,
        'bid'        => 120.679,
        'count'      => 14,
        'epoch'      => 1446194685,
        'quote'      => 120.684,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194700,
        'ask'        => 120.687,
        'bid'        => 120.684,
        'count'      => 15,
        'epoch'      => 1446194700,
        'quote'      => 120.685,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194715,
        'ask'        => 120.693,
        'bid'        => 120.69,
        'count'      => 15,
        'epoch'      => 1446194715,
        'quote'      => 120.691,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194730,
        'ask'        => 120.697,
        'bid'        => 120.689,
        'count'      => 15,
        'epoch'      => 1446194730,
        'quote'      => 120.693,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194745,
        'ask'        => 120.708,
        'bid'        => 120.701,
        'count'      => 15,
        'epoch'      => 1446194745,
        'quote'      => 120.704,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194760,
        'ask'        => 120.7,
        'bid'        => 120.676,
        'count'      => 14,
        'epoch'      => 1446194760,
        'quote'      => 120.688,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194775,
        'ask'        => 120.7,
        'bid'        => 120.692,
        'count'      => 15,
        'epoch'      => 1446194775,
        'quote'      => 120.696,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194790,
        'ask'        => 120.69,
        'bid'        => 120.684,
        'count'      => 15,
        'epoch'      => 1446194790,
        'quote'      => 120.687,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194805,
        'ask'        => 120.696,
        'bid'        => 120.681,
        'count'      => 15,
        'epoch'      => 1446194805,
        'quote'      => 120.689,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194820,
        'ask'        => 120.686,
        'bid'        => 120.683,
        'count'      => 13,
        'epoch'      => 1446194820,
        'quote'      => 120.685,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'agg_epoch'  => 1446194835,
        'ask'        => 120.687,
        'bid'        => 120.681,
        'count'      => 14,
        'epoch'      => 1446194835,
        'quote'      => 120.684,
        'symbol'     => 'frxUSDJPY',
    },
    {
        'ask'        => 120.673,
        'bid'        => 120.67,
        'count'      => 1,
        'epoch'      => 1446194861,
        'quote'      => 120.672,
        'symbol'     => 'frxUSDJPY',
    }];

subtest 'general' => sub {
    lives_ok {
        BOM::MarketData::VolSurface::Empirical->new(underlying => 'frxUSDJPY');
    }
    'ok to create Emprical object with frxUSDJPY';
    throws_ok {
        BOM::MarketData::VolSurface::Empirical->new();
    }
    qr/is required/, 'throws error if underlying is not specified';
};

my $mock_at = Test::MockModule->new('BOM::Market::AggTicks');

my $mock_emp = Test::MockModule->new('BOM::MarketData::VolSurface::Empirical');
$mock_emp->mock('long_term_vol', sub { 0.11 });

subtest 'error check' => sub {
    lives_ok {
        $mock_at->mock('retrieve', sub { [] });
        my $vs = BOM::MarketData::VolSurface::Empirical->new(underlying => 'frxUSDJPY');
        is $vs->get_volatility({
                current_epoch         => $now->epoch,
                seconds_to_expiration => 900
            }
            ),
            0.11, 'vol is 0.11';
        ok $vs->error, 'error flagged when ticks are empty';
        $mock_at->mock(
            'retrieve',
            sub {
                [map { $ticks->[$_] } (0 .. 3)];
            });
        is $vs->get_volatility({
                current_epoch         => $now->epoch,
                seconds_to_expiration => 900
            }
            ),
            0.11, 'vol is 0.11';
        ok $vs->error, 'error flagged when ticks has less than or equals to 4 elements';
        $mock_at->mock(
            'retrieve',
            sub {
                [map { $ticks->[$_] } (0 .. 46)];
            });
        is $vs->get_volatility({
                current_epoch         => $now->epoch,
                seconds_to_expiration => 900
            }
            ),
            0.11, 'vol is 0.11';
        ok $vs->error, 'error flagged when ticks has less than or equals to 4 elements';
        is $vs->get_volatility({current_epoch => $now->epoch}), 0.11, 'vol is 0.11';
        ok $vs->error, 'error if seconds_to_expiration is not provided';
        is $vs->get_volatility({seconds_to_expiration => 900}), 0.11, 'vol is 0.11';
        ok $vs->error, 'error if current_epoch is not provided';
    }
    'lives through error check';
};

subtest 'seasonalized volatility' => sub {
    $mock_at->mock('retrieve', sub { $ticks });
    lives_ok {
        my $vs = BOM::MarketData::VolSurface::Empirical->new(underlying => 'frxUSDJPY');
        is $vs->get_volatility({
                current_epoch         => $now->epoch,
                seconds_to_expiration => 900
            }
            ),
            0.0944480459725993, '';
    }
    'lives through process of getting seasonalized volatility';
};

subtest 'seasonalized volatility with news' => sub {
    my $eco_data = {
        symbol        => 'USD',
        release_date  => $now,
        impact        => 1,
        event_name    => 'CB Leading Index m/m',
        recorded_date => $now,
        source        => 'forexfactory'
    };
    lives_ok {
        my $vs = BOM::MarketData::VolSurface::Empirical->new(underlying => 'frxAUDJPY');
        is $vs->get_volatility({
                current_epoch         => $now->epoch,
                seconds_to_expiration => 900,
                economic_events       => [$eco_data],
                include_news_impact   => 1
            }
            ),
            0.226011967175762, '';
        ok !$vs->error, 'no error';
    }
    'lives through process of getting seasonalized volatility';
    my $uncategorized = {
        symbol        => 'USD',
        release_date  => $now->minus_time_interval('30m'),
        impact        => 3,
        event_name    => 'Construction Spending m/m',
        recorded_date => $now,
        source        => 'forexfactory'
    };
    lives_ok {
        my $vs = BOM::MarketData::VolSurface::Empirical->new(underlying => 'frxUSDJPY');
        is $vs->get_volatility({
                current_epoch         => $now->epoch,
                seconds_to_expiration => 900,
                economic_events       => [$uncategorized],
                include_news_impact   => 1
            }
            ),
            0.0944480459725993, '';
        ok !$vs->error, 'no error';
    }
    'lives through process of getting seasonalized volatility';
};

