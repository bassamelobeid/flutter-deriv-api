use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Runtime qw(:normal);
use Date::Utility;
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Market::Underlying;
use BOM::MarketData::VolSurface::Delta;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::MarketData::VolSurface::Validator;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Platform::Static::Config;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD EUR/);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'GDAXI',
        date   => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'GDAXI',
        recorded_date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_100',
        date   => Date::Utility->new
    });

initialize_realtime_ticks_db();

my %surface_data = (
    1 => {
        smile => {
            25 => 0.16953,
            50 => 0.175,
            75 => 0.18453
        },
        vol_spread => {50 => 0.03}
    },
    7 => {
        smile => {
            25 => 0.13535,
            50 => 0.1385,
            75 => 0.14675
        },
        vol_spread => {50 => 0.003}
    },
    30 => {
        smile => {
            25 => 0.14069,
            50 => 0.155,
            75 => 0.17406
        },
        vol_spread => {50 => 0}
    },
    60 => {
        smile => {
            25 => 0.13831,
            50 => 0.154,
            75 => 0.17744
        },
        vol_spread => {50 => 0.001}
    },
    90 => {
        smile => {
            25 => 0.13856,
            50 => 0.1555,
            75 => 0.18144
        },
        vol_spread => {50 => 0.001}
    },
    180 => {
        smile => {
            25 => 0.14019,
            50 => 0.1565,
            75 => 0.18344
        },
        vol_spread => {50 => 0.001}
    },
    365 => {
        smile => {
            25 => 0.143,
            50 => 0.15725,
            75 => 0.19113
        },
        vol_spread => {50 => 0.0025}
    },
);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'JPY',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        type         => 'implied',
        implied_from => 'USD',
        date         => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'EUR',
        rates  => {
            1   => 0.2,
            2   => 0.15,
            7   => 0.18,
            32  => 0.25,
            62  => 0.2,
            92  => 0.18,
            186 => 0.1,
            365 => 0.13,
        },
        type         => 'implied',
        implied_from => 'USD',
        date         => Date::Utility->new,
    });

my $validator = BOM::MarketData::VolSurface::Validator->new;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for (qw(USD EUR-USD USD-EUR));

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        surface       => \%surface_data,
        recorded_date => Date::Utility->new,
    });

subtest 'Unit test tools.' => sub {
    $surface_data{1}->{smile}->{50} = 0.17;
    my $sample_surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxEURUSD',
            surface       => \%surface_data,
            recorded_date => Date::Utility->new,
            save          => 0,
        });
    lives_ok { $validator->validate_surface($sample_surface) } 'Our default sample surface is valid.';
};

subtest _check_age => sub {
    plan tests => 2;

    my $old_date = Date::Utility->new(time - 7201);
    my $sample   = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxEURUSD',
            surface       => \%surface_data,
            recorded_date => $old_date,
            save          => 0,
        });
    throws_ok {
        $validator->validate_surface($sample);
    }
    qr/more than 2 hours/, 'Old vol surface.';

    my $acceptable_date = Date::Utility->new(time - 7199);
    $sample = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxEURUSD',
            surface       => \%surface_data,
            recorded_date => $acceptable_date,
            save          => 0,
        });
    lives_ok {
        $validator->validate_surface($sample);
    }
    'Age of vol surface acceptable.';
};

subtest '_check_structure' => sub {
    throws_ok {
        $validator->validate_surface(
            BOM::MarketData::VolSurface::Delta->new(
                underlying    => BOM::Market::Underlying->new('frxEURUSD'),
                surface       => {},
                recorded_date => Date::Utility->new,
            ));
    }
    qr/Must be at least two maturities on vol surface/, 'No maturities on surface.';

    throws_ok {
        $validator->validate_surface(_sample_surface({surface => {7 => {}}}));
    }
    qr/Must be at least two maturities on vol surface/, 'Only one maturity on surface.';

    throws_ok {
        $validator->validate_surface(
            _sample_surface({
                    surface => {
                        1  => {smile => {50 => 0.2}},
                        -1 => {}}}));
    }
    qr/positive numeric days/, 'Maturity on surface too small.';

    throws_ok {
        my $sample = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'volsurface_delta',
            {
                symbol  => 'frxEURUSD',
                surface => {
                    1 => {
                        smile => {
                            50 => 0.2,
                            25 => => 0.2,
                            75 => 0.2
                        }
                    },
                    381 => {
                        smile => {
                            50 => 0.2,
                            25 => => 0.2,
                            75 => 0.2
                        }}
                },
                recorded_date => Date::Utility->new,
            });

        $validator->validate_surface($sample);
    }
    qr/Day.381. in volsurface for underlying\S+ greater than allowed/, 'Maturity on surface too big.';

    throws_ok {
        my $sample = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'volsurface_delta',
            {
                symbol  => 'frxEURUSD',
                surface => {
                    1  => {smile => {50 => 0.2}},
                    7  => {smile => {50 => 0.2}},
                    14 => {}
                },
                recorded_date => Date::Utility->new,
                save          => 0,
            });
        $validator->validate_surface($sample);
    }
    qr/Missing both smile and atm_spread/, 'No smile or atm_spread on valid maturity.';

    # Smiles and ATM spreads:
    warning_like {
        throws_ok {
            $validator->validate_surface(
                BOM::MarketData::VolSurface::Delta->new(
                    underlying => BOM::Market::Underlying->new('frxEURUSD'),
                    surface    => {
                        1 => {
                            smile => {
                                banana => 0.13535,
                                50     => 0.1385,
                                75     => 0.14675,
                            },
                        },
                        7 => {
                            smile => {
                                25 => 0.13535,
                                50 => 0.1385,
                                75 => 0.14675,
                            },
                        },
                    },
                    recorded_date => Date::Utility->new,
                    deltas        => ['banana', 50, 75],
                ));
        }
        qr/Invalid vol_point.banana./, 'Invalid delta.';
    }
    qr/Argument "banana" isn't numeric /, 'Invalid delta test warns.';

    throws_ok {
        my $sample = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
            'volsurface_delta',
            {
                symbol  => 'frxEURUSD',
                surface => {
                    7 => {
                        smile => {
                            25 => 0.13535,
                            50 => 0.1385,
                            75 => 0.14675,
                        },
                        vol_spread => {50 => 0.03},
                    },
                    14 => {
                        smile => {
                            24 => 0.13535,
                            50 => 0.1385,
                            75 => 0.14675,
                        },
                        vol_spread => {50 => 0.03},
                    },
                },
                recorded_date => Date::Utility->new,
                save          => 0,
            });
        $validator->validate_surface($sample);
    }
    qr/Deltas.24,50,75. for maturity.14., underlying\S+ are not the same as deltas for rest of surface/, 'Inconsistent deltas.';

    throws_ok {
        $validator->validate_surface(
            BOM::MarketData::VolSurface::Delta->new(
                underlying => BOM::Market::Underlying->new('frxEURUSD'),
                deltas     => [15, 50, 85],
                surface    => {
                    1 => {
                        smile => {
                            15 => 0.16953,
                            50 => 0.175,
                            85 => 0.18453
                        },
                        vol_spread => {50 => 0.03}
                    },
                    7 => {
                        smile => {
                            15 => 0.13535,
                            50 => 0.1385,
                            85 => 0.14675
                        },
                        vol_spread => {50 => 0.003}
                    },
                },
                recorded_date => Date::Utility->new,
            ));
    }
    qr/Difference between point 15 and 50 too great/, 'Too great a difference between delta points.';
};

subtest _check_smiles => sub {
    plan tests => 1;

    my $smile = {
        25 => 0.05,
        50 => 'invalid string',
        75 => 0.04,
    };
    throws_ok {
        $validator->check_smile(7, $smile);
    }
    qr/Invalid smile volatility for/, 'Invalid vol format.';
};

subtest _check_termstructure_for_calendar_arbitrage => sub {
    plan tests => 1;

    my $surface = BOM::MarketData::VolSurface::Delta->new(
        underlying => BOM::Market::Underlying->new('frxEURUSD'),
        deltas     => [25, 50, 75],
        surface    => {
            1 => {
                smile => {
                    25 => 0.29,
                    50 => 0.28,
                    75 => 0.29
                },
                vol_spread => {50 => 0.03}
            },
            7 => {
                smile => {
                    25 => 0.11,
                    50 => 0.10,
                    75 => 0.11
                },
                vol_spread => {50 => 0.003}
            },
        },
        recorded_date => Date::Utility->new,
    );

    $validator->validate_surface($surface);
    like($surface->get_smile_flags, qr/Variance negative/, 'Negative Variance check');

};

subtest 'partial surface data' => sub {
    plan tests => 1;
    my $sample = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            recorded_date => Date::Utility->new,
            surface       => {
                1 => {
                    smile => {
                        25 => 0.225,
                        50 => 0.25,
                        75 => 0.275
                    }
                },
                7  => {vol_spread => {50 => 0.01}},
                14 => {
                    smile => {
                        25 => 0.325,
                        50 => 0.35,
                        75 => 0.375
                    }
                },
                21 => {vol_spread => {50 => 0.02}},
            },
            symbol => 'frxEURUSD',
            save   => 0,
        },
    );

    lives_ok {
        $validator->validate_surface($sample);
    }
    'Can create a surface with partial smile and atm_spread info.';
};

subtest 'Admissible Checks 1 & 2: Strike related.' => sub {
    plan tests => 1;

    # Setting this increases our tolerance for jumps in the vol across smiles,
    # allowing this test data to get through to the check that's supposed to catch it.
    BOM::Platform::Static::Config::quants->{market_data}->{extra_vol_diff_by_delta} = 5;

    # Need an existing USDJPY surface in place...
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol  => 'frxEURUSD',
            surface => {
                7 => {
                    smile => {
                        25 => 0.78,
                        50 => 0.67,
                        75 => 0.11,
                    },
                    vol_spread => {50 => 0.03},
                },
                14 => {
                    smile => {
                        25 => 0.78,
                        50 => 0.71,
                        75 => 0.12,
                    },
                    vol_spread => {50 => 0.03},
                },
            },
            recorded_date => Date::Utility->new,
        });

    my %surface_data = (
        7 => {
            smile => {
                25 => 0.8,
                50 => 0.7,
                75 => 0.1,
            },
            vol_spread => {50 => 0.03},
        },
        14 => {
            smile => {
                25 => 0.8,
                50 => 0.7,
                75 => 0.1,
            },
            vol_spread => {50 => 0.03},
        },
    );
    my $surface = BOM::MarketData::VolSurface::Delta->new(
        underlying    => BOM::Market::Underlying->new('frxEURUSD'),
        surface       => \%surface_data,
        recorded_date => Date::Utility->new,
    );

    throws_ok {
        $validator->validate_surface($surface);
    }
    qr/Admissible check 1 failure/, 'Admissible check 1 failure.';
};

subtest 'Moneyness surfaces' => sub {
    plan tests => 2;
    my $surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            recorded_date => Date::Utility->new,
            save          => 0,
        });
    $surface->surface->{7}->{smile}->{100} = 0.26;
    # check that a valid moneyness surface is valid
    lives_ok { $validator->validate_surface($surface) } 'Our default moneyness sample surface is valid.';

    # check that a surface that should fail Ad#2 does indeed fail.
    $surface = BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            surface => {
                30 => {
                    smile => {
                        80  => 0.2761,
                        82  => 0.2761,
                        84  => 0.2761,
                        86  => 0.2761,
                        88  => 0.2761,
                        90  => 0.2761,
                        92  => 0.2761,
                        94  => 0.2761,
                        96  => 0.2761,
                        98  => 0.2761,
                        100 => 0.2761,
                        102 => 0.2961,
                        104 => 0.2761,
                        106 => 0.2761,
                        108 => 0.2761,
                        110 => 0.2761,
                        112 => 0.2761,
                        114 => 0.2761,
                        116 => 0.2761,
                        118 => 0.2761,
                        120 => 0.2761,
                    },
                    vol_spread => {50 => 0.0012},
                },
                7 => {
                    smile => {
                        80  => 0.2761,
                        82  => 0.2761,
                        84  => 0.2761,
                        86  => 0.2761,
                        88  => 0.2761,
                        90  => 0.2761,
                        92  => 0.2761,
                        94  => 0.2761,
                        96  => 0.2761,
                        98  => 0.2761,
                        100 => 0.2761,
                        102 => 0.2761,
                        104 => 0.2761,
                        106 => 0.2761,
                        108 => 0.2761,
                        110 => 0.2761,
                        112 => 0.2761,
                        114 => 0.2761,
                        116 => 0.2761,
                        118 => 0.2761,
                        120 => 0.2761,
                    },
                    vol_spread => {50 => 0.0012},
                },

            },
            recorded_date => Date::Utility->new,
            save          => 0,
        });

    throws_ok {
        $validator->validate_surface($surface);
    }
    qr/Admissible check 2/, 'Convexity Check';
};

sub _sample_surface {
    my $args   = shift || {};
    my $symbol = shift || 'frxEURUSD';

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol               => $symbol,
            surface              => \%surface_data,
            _default_cutoff_list => [],
            %$args,
            recorded_date => Date::Utility->new,
        });

    return BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => BOM::Market::Underlying->new($symbol)});
}

done_testing;
