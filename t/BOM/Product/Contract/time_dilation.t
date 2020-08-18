#
# PURPOSE: Price a bet through an hour of its life.
#

use strict;
use warnings;

use Test::Most;
use Test::Warnings;
use Test::MockModule;
use File::Spec;

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

use Date::Utility;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::Config::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis;

my $now  = Date::Utility->new('2012-01-19T01:00:00Z')->epoch;
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxEURUSD',
    epoch      => $now,
    quote      => 1
});

my %bet_params = (
    bet_type     => 'NOTOUCH',
    date_start   => $now,
    date_expiry  => '2012-01-20 23:59:59',
    underlying   => 'frxEURUSD',
    payout       => 100,
    current_tick => $tick,
    barrier      => 1.30,
    currency     => 'AUD',
);

my %historical = (
    currency => {
        AUD => [{
                recorded_date => '2012-01-19T00:00:00Z',
                rates         => {
                    1 => 0.01,
                    2 => 0.01
                },
            },
            {
                recorded_date => '2012-01-19T01:01:01Z',
                rates         => {
                    1 => 0.05,
                    2 => 0.05
                },
            },
            {
                recorded_date => '2012-01-19T01:51:01Z',
                rates         => {
                    1 => 0.10,
                    2 => 0.10
                },
            },
        ],
        'AUD-EUR' => [{
                recorded_date => '2012-01-19T00:00:00Z',
                rates         => {
                    1 => 0.01,
                    2 => 0.01
                },
            },
            {
                recorded_date => '2012-01-19T01:01:01Z',
                rates         => {
                    1 => 0.05,
                    2 => 0.05
                },
            },
            {
                recorded_date => '2012-01-19T01:51:01Z',
                rates         => {
                    1 => 0.10,
                    2 => 0.10
                },
            },
        ],
        USD => [{
                recorded_date => '2012-01-19T00:00:00Z',
                rates         => {
                    1 => 0.08,
                    2 => 0.08
                },
            },
            {
                recorded_date => '2012-01-19T01:21:01Z',
                rates         => {
                    1 => 0.04,
                    2 => 0.04
                },
            },
            {
                recorded_date => '2012-01-19T01:31:01Z',
                rates         => {
                    1 => 0.02,
                    2 => '0.02'
                },
            },
        ],
        EUR => [{
                recorded_date => '2012-01-19T00:00:00Z',
                rates         => {
                    1 => 0.05,
                    2 => 0.05
                },
            },
            {
                recorded_date => '2012-01-19T01:12:01Z',
                rates         => {
                    1 => 0.07,
                    2 => 0.07
                },
            },
            {
                recorded_date => '2012-01-19T01:41:01Z',
                rates         => {
                    1 => 0.04,
                    2 => 0.04
                },
            },
        ],
        'EUR-USD' => [{
                recorded_date => '2012-01-19T00:00:00Z',
                rates         => {
                    1 => 0.08,
                    2 => 0.08
                },
            },
            {
                recorded_date => '2012-01-19T01:21:01Z',
                rates         => {
                    1 => 0.04,
                    2 => 0.04
                },
            },
            {
                recorded_date => '2012-01-19T01:31:01Z',
                rates         => {
                    1 => 0.02,
                    2 => '0.02'
                },
            },
        ],
    },
    volsurface_delta => {
        frxEURUSD => [{
                recorded_date => '2012-01-19T00:00:00Z',
                master_cutoff => 'New York 10:00',
                surface       => {
                    2 => {
                        vol_spread => {50 => 0.01},
                        smile      => {
                            25 => 0.1615,
                            50 => 0.1578,
                            75 => 0.1630
                        }}}
            },
            {
                recorded_date => '2012-01-19T01:20:01Z',
                master_cutoff => 'New York 10:00',
                surface       => {
                    2 => {
                        vol_spread => {50 => 0.04},
                        smile      => {
                            25 => 0.1715,
                            50 => 0.1678,
                            75 => 0.1730
                        }}}
            },
            {
                recorded_date => '2012-01-19T01:40:01Z',
                master_cutoff => 'New York 10:00',
                surface       => {
                    2 => {
                        vol_spread => {50 => 0.03},
                        smile      => {
                            25 => 0.1515,
                            50 => 0.1478,
                            75 => 0.1530
                        }}}
            },
        ],
        frxEURAUD => [{
                recorded_date => '2012-01-19T00:00:00Z',
                master_cutoff => 'New York 10:00',
                surface       => {
                    2 => {
                        vol_spread => {50 => 0.061},
                        smile      => {
                            25 => 0.0975,
                            50 => 0.092,
                            75 => 0.0925
                        }}}
            },
            {
                recorded_date => '2012-01-19T01:15:01Z',
                master_cutoff => 'New York 10:00',
                surface       => {
                    2 => {
                        vol_spread => {50 => 0.05},
                        smile      => {
                            25 => 0.0875,
                            50 => 0.082,
                            75 => 0.0825
                        }}}
            },
            {
                recorded_date => '2012-01-19T01:30:01Z',
                master_cutoff => 'New York 10:00',
                surface       => {
                    2 => {
                        vol_spread => {50 => 0.10},
                        smile      => {
                            25 => 0.1075,
                            50 => 0.102,
                            75 => 0.1025
                        }}}
            },
        ],
        frxAUDUSD => [{
                recorded_date => '2012-01-19T00:00:00Z',
                master_cutoff => 'New York 10:00',
                surface       => {
                    2 => {
                        vol_spread => {50 => 0.025},
                        smile      => {
                            25 => 0.155,
                            50 => 0.155,
                            75 => 0.160
                        }}}
            },
            {
                recorded_date => '2012-01-19T01:18:01Z',
                master_cutoff => 'New York 10:00',
                surface       => {
                    2 => {
                        vol_spread => {50 => 0.05},
                        smile      => {
                            25 => 0.255,
                            50 => 0.255,
                            75 => 0.260
                        }}}
            },
            {
                recorded_date => '2012-01-19T01:48:02Z',
                master_cutoff => 'New York 10:00',
                surface       => {
                    2 => {
                        vol_spread => {50 => 0.03},
                        smile      => {
                            25 => 0.165,
                            50 => 0.165,
                            75 => 0.170
                        }}}
            },
        ],
    },
);

# Now we'll muck up any historical data in the chronicle unit test DB and
# replace it with our own crazy values.
foreach my $fixture_type (keys %historical) {
    for my $symbol (sort keys %{$historical{$fixture_type}}) {
        my $fixtures = $historical{$fixture_type}{$symbol};
        foreach my $fixture (@{$fixtures}) {
            $fixture->{symbol} = $symbol;
            foreach my $date_key (qw(date recorded_date)) {
                $fixture->{$date_key} = Date::Utility->new($fixture->{$date_key})
                    if exists $fixture->{$date_key};
            }
            BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
                $fixture_type,
                {
                    symbol => $fixture->{symbol},
                    %$fixture,
                });
        }
    }
}

my %previous = (
    frxEURUSD => {
        date          => '2012-01-19T00:00:00Z',
        date_changed  => 0,
        value         => undef,
        value_changed => 0
    },
    frxEURAUD => {
        date          => '2012-01-19T00:00:00Z',
        date_changed  => 0,
        value         => undef,
        value_changed => 0
    },
    frxAUDUSD => {
        date          => '2012-01-19T00:00:00Z',
        date_changed  => 0,
        value         => undef,
        value_changed => 0
    },
    EUR => {
        date          => '2012-01-19T00:00:00Z',
        date_changed  => 0,
        value         => undef,
        value_changed => 0,
    },
    USD => {
        date          => '2012-01-19T00:00:00Z',
        date_changed  => 0,
        value         => undef,
        value_changed => 0,
    },
    AUD => {
        date          => '2012-01-19T00:00:00Z',
        date_changed  => 0,
        value         => undef,
        value_changed => 0,
    },
);

my $start = Date::Utility->new('2012-01-19T00:59:00Z');
my $end   = Date::Utility->new('2012-01-19T02:00:00Z');

for (my $time = $start->epoch; $time <= $end->epoch; $time += 300) {
    my $when = Date::Utility->new($time);
    $bet_params{date_pricing} = $when;

    my $bet        = produce_contract(\%bet_params);
    my $price_date = $bet->date_pricing->datetime_iso8601;
    my %current    = (
        frxEURUSD => {
            date  => $bet->volsurface->creation_date->datetime_iso8601,
            value => $bet->atm_vols->{fordom},
        },
        frxEURAUD => {
            date  => $bet->forqqq->{volsurface}->creation_date->datetime_iso8601,
            value => $bet->atm_vols->{forqqq},
        },
        frxAUDUSD => {
            date  => $bet->domqqq->{volsurface}->creation_date->datetime_iso8601,
            value => $bet->atm_vols->{domqqq},
        },
        USD => {
            date  => $bet->underlying->quoted_currency->interest->recorded_date->datetime_iso8601,
            value => $bet->q_rate,
        },
        EUR => {
            date  => $bet->underlying->asset->interest->recorded_date->datetime_iso8601,
            value => $bet->r_rate,
        },
        AUD => {
            date  => $bet->forqqq->{underlying}->quoted_currency->interest->recorded_date->datetime_iso8601,
            value => $bet->discount_rate,
        },
    );

    foreach my $symbol (keys %current) {
        cmp_ok($current{$symbol}->{date}, 'ge', $previous{$symbol}->{date}, $symbol . ' data did not move backward while we were moving forward.');
        cmp_ok($current{$symbol}->{date}, 'le', $price_date,                $symbol . ' data is in the past from the pricing date.');
        foreach my $wha (qw(date value)) {
            $previous{$symbol}->{$wha} ||= $current{$symbol}->{$wha};
            if ($wha eq 'date' and $current{$symbol}->{$wha} ne $previous{$symbol}->{$wha}) {
                $previous{$symbol}->{$wha . '_changed'}++;
                # get_volatility interface changes, it won't exactly match the numbers but close enough.
            } elsif ($wha eq 'value' and abs($current{$symbol}->{$wha} - $previous{$symbol}->{$wha}) > 0.0000001) {
                $previous{$symbol}->{$wha . '_changed'}++;
            }
            $previous{$symbol}->{$wha} = $current{$symbol}->{$wha};
        }
    }
    # This is mostly here so that if the integral days thing changes we'll notice.
    # It will break other tests later, if not.
    is($bet->timeindays->amount, ($bet->date_expiry->epoch - $bet->effective_start->epoch) / 86400, 'exact duration of bet.');
}

foreach my $symbol (sort keys %previous) {
    if ($symbol =~ /frx/) {
        is($previous{$symbol}->{'date_changed'},  2,  $symbol . ' date changed twice.');
        is($previous{$symbol}->{'value_changed'}, 12, $symbol . ' value changed 12 times due to pricing at different interval (seasonality affect).');
    } else {
        foreach my $wha (qw(date value)) {
            is($previous{$symbol}->{$wha . '_changed'}, 2, $symbol . ' ' . $wha . ' changed twice.');
        }
    }
}

done_testing;
