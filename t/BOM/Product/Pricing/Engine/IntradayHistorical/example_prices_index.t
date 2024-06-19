#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More (tests => 5);
use Test::Warnings;
use Date::Utility;
use Text::CSV::Slurp;
use Format::Util::Numbers qw/roundcommon/;

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);
use BOM::MarketData                              qw(create_underlying_db);
use BOM::Product::ContractFactory                qw( produce_contract );
use BOM::MarketData                              qw(create_underlying);
use BOM::MarketData::Types;

use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

BOM::Config::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom-test/feed/combined');

my @symbols = map { create_underlying($_) } create_underlying_db->symbols_for_intraday_index;

my $corr = {
    'OTC_FCHI' => {
        'GBP' => {
            '3M'  => '-0.1',
            '12M' => '-0.046',
            '6M'  => '-0.082',
            '9M'  => '-0.064'
        },
        'AUD' => {
            '3M'  => '-0.21',
            '12M' => '-0.204',
            '6M'  => '-0.208',
            '9M'  => '-0.206'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.651',
            '12M' => '-0.451',
            '6M'  => '-0.568',
            '9M'  => '-0.503'
        }
    },
    'RTSI' => {
        'GBP' => {
            '3M'  => '-0.314',
            '12M' => '-0.257',
            '6M'  => '-0.295',
            '9M'  => '-0.276'
        },
        'AUD' => {
            '3M'  => '-0.208',
            '12M' => '-0.187',
            '6M'  => '-0.2',
            '9M'  => '-0.193'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.702',
            '12M' => '-0.461',
            '6M'  => '-0.602',
            '9M'  => '-0.523'
        }
    },
    'OTC_SPC' => {
        'GBP' => {
            '3M'  => '-0.112',
            '12M' => '-0.157',
            '6M'  => '-0.131',
            '9M'  => '-0.145'
        },
        'AUD' => {
            '3M'  => '-0.051',
            '12M' => '-0.112',
            '6M'  => '-0.076',
            '9M'  => '-0.096'
        },
        'EUR' => {
            '3M'  => '-0.001',
            '12M' => '0.009',
            '6M'  => '0.002',
            '9M'  => '0.006'
        },
        'USD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        }
    },
    'NIFTY' => {
        'GBP' => {
            '3M'  => '-0.112',
            '12M' => '-0.157',
            '6M'  => '-0.131',
            '9M'  => '-0.145'
        },
        'AUD' => {
            '3M'  => '-0.051',
            '12M' => '-0.112',
            '6M'  => '-0.076',
            '9M'  => '-0.096'
        },
        'EUR' => {
            '3M'  => '-0.001',
            '12M' => '0.009',
            '6M'  => '0.002',
            '9M'  => '0.006'
        },
        'USD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        }
    },
    'OTC_GDAXI' => {
        'GBP' => {
            '3M'  => '-0.091',
            '12M' => '-0.051',
            '6M'  => '-0.078',
            '9M'  => '-0.064'
        },
        'AUD' => {
            '3M'  => '-0.092',
            '12M' => '-0.1',
            '6M'  => '-0.096',
            '9M'  => '-0.098'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.253',
            '12M' => '-0.143',
            '6M'  => '-0.217',
            '9M'  => '-0.18'
        }
    },
    'OTC_N225' => {
        'GBP' => {
            '3M'  => '0.447',
            '12M' => '0.472',
            '6M'  => '0.458',
            '9M'  => '0.466'
        },
        'AUD' => {
            '3M'  => '0.605',
            '12M' => '0.499',
            '6M'  => '0.561',
            '9M'  => '0.527'
        },
        'EUR' => {
            '3M'  => '0.56',
            '12M' => '0.693',
            '6M'  => '0.615',
            '9M'  => '0.658'
        },
        'USD' => {
            '3M'  => '0.785',
            '12M' => '0.708',
            '6M'  => '0.753',
            '9M'  => '0.728'
        }
    },
    'OTC_FTSE' => {
        'GBP' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'AUD' => {
            '3M'  => '0.032',
            '12M' => '0.009',
            '6M'  => '0.025',
            '9M'  => '0.017'
        },
        'EUR' => {
            '3M'  => '0.221',
            '12M' => '0.18',
            '6M'  => '0.208',
            '9M'  => '0.194'
        },
        'USD' => {
            '3M'  => '0.326',
            '12M' => '0.265',
            '6M'  => '0.306',
            '9M'  => '0.285'
        }
    },
    'SZSECOMP' => {
        'GBP' => {
            '3M'  => '-0.112',
            '12M' => '-0.157',
            '6M'  => '-0.131',
            '9M'  => '-0.145'
        },
        'AUD' => {
            '3M'  => '-0.051',
            '12M' => '-0.112',
            '6M'  => '-0.076',
            '9M'  => '-0.096'
        },
        'EUR' => {
            '3M'  => '-0.001',
            '12M' => '0.009',
            '6M'  => '0.002',
            '9M'  => '0.006'
        },
        'USD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        }
    },
    'OTC_SSMI' => {
        'GBP' => {
            '3M'  => '0.16',
            '12M' => '0.231',
            '6M'  => '0.19',
            '9M'  => '0.213'
        },
        'AUD' => {
            '3M'  => '-0.242',
            '12M' => '-0.304',
            '6M'  => '-0.267',
            '9M'  => '-0.288'
        },
        'EUR' => {
            '3M'  => '-0.26',
            '12M' => '-0.15',
            '6M'  => '-0.224',
            '9M'  => '-0.187'
        },
        'USD' => {
            '3M'  => '0.172',
            '12M' => '0.305',
            '6M'  => '0.227',
            '9M'  => '0.271'
        }
    },
    'N150' => {
        'GBP' => {
            '3M'  => '-0.314',
            '12M' => '-0.257',
            '6M'  => '-0.295',
            '9M'  => '-0.276'
        },
        'AUD' => {
            '3M'  => '-0.208',
            '12M' => '-0.187',
            '6M'  => '-0.2',
            '9M'  => '-0.193'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.702',
            '12M' => '-0.461',
            '6M'  => '-0.602',
            '9M'  => '-0.523'
        }
    },
    'OTC_SX5E' => {
        'GBP' => {
            '3M'  => '-0.314',
            '12M' => '-0.257',
            '6M'  => '-0.295',
            '9M'  => '-0.276'
        },
        'AUD' => {
            '3M'  => '-0.208',
            '12M' => '-0.187',
            '6M'  => '-0.2',
            '9M'  => '-0.193'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.702',
            '12M' => '-0.461',
            '6M'  => '-0.602',
            '9M'  => '-0.523'
        }
    },
    'OTC_HSI' => {
        'GBP' => {
            '3M'  => '0.447',
            '12M' => '0.472',
            '6M'  => '0.458',
            '9M'  => '0.466'
        },
        'AUD' => {
            '3M'  => '0.605',
            '12M' => '0.499',
            '6M'  => '0.561',
            '9M'  => '0.527'
        },
        'EUR' => {
            '3M'  => '0.56',
            '12M' => '0.693',
            '6M'  => '0.615',
            '9M'  => '0.658'
        },
        'USD' => {
            '3M'  => '0.785',
            '12M' => '0.708',
            '6M'  => '0.753',
            '9M'  => '0.728'
        }
    },
    'OTC_NDX' => {
        'GBP' => {
            '3M'  => '-0.008',
            '12M' => '-0.11',
            '6M'  => '-0.05',
            '9M'  => '-0.084'
        },
        'AUD' => {
            '3M'  => '0.093',
            '12M' => '0.07',
            '6M'  => '0.086',
            '9M'  => '0.078'
        },
        'EUR' => {
            '3M'  => '0.012',
            '12M' => '0.062',
            '6M'  => '0.033',
            '9M'  => '0.049'
        },
        'USD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        }
    },
    'IXIC' => {
        'GBP' => {
            '3M'  => '-0.008',
            '12M' => '-0.11',
            '6M'  => '-0.05',
            '9M'  => '-0.084'
        },
        'AUD' => {
            '3M'  => '0.093',
            '12M' => '0.07',
            '6M'  => '0.086',
            '9M'  => '0.078'
        },
        'EUR' => {
            '3M'  => '0.012',
            '12M' => '0.062',
            '6M'  => '0.033',
            '9M'  => '0.049'
        },
        'USD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        }
    },
    'PSI20' => {
        'GBP' => {
            '3M'  => '-0.1',
            '12M' => '-0.046',
            '6M'  => '-0.082',
            '9M'  => '-0.064'
        },
        'AUD' => {
            '3M'  => '-0.21',
            '12M' => '-0.204',
            '6M'  => '-0.208',
            '9M'  => '-0.206'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.651',
            '12M' => '-0.451',
            '6M'  => '-0.568',
            '9M'  => '-0.503'
        }
    },
    'KOSPI2' => {
        'GBP' => {
            '3M'  => '-0.112',
            '12M' => '-0.157',
            '6M'  => '-0.131',
            '9M'  => '-0.145'
        },
        'AUD' => {
            '3M'  => '-0.051',
            '12M' => '-0.112',
            '6M'  => '-0.076',
            '9M'  => '-0.096'
        },
        'EUR' => {
            '3M'  => '-0.001',
            '12M' => '0.009',
            '6M'  => '0.002',
            '9M'  => '0.006'
        },
        'USD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        }
    },
    'IBOV' => {
        'GBP' => {
            '3M'  => '-0.314',
            '12M' => '-0.257',
            '6M'  => '-0.295',
            '9M'  => '-0.276'
        },
        'AUD' => {
            '3M'  => '-0.208',
            '12M' => '-0.187',
            '6M'  => '-0.2',
            '9M'  => '-0.193'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.702',
            '12M' => '-0.461',
            '6M'  => '-0.602',
            '9M'  => '-0.523'
        }
    },
    'OTC_AS51' => {
        'GBP' => {
            '3M'  => '-0.112',
            '12M' => '-0.157',
            '6M'  => '-0.131',
            '9M'  => '-0.145'
        },
        'AUD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'EUR' => {
            '3M'  => '-0.001',
            '12M' => '0.009',
            '6M'  => '0.002',
            '9M'  => '0.006'
        },
        'USD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        }
    },
    'FTSEMIB' => {
        'GBP' => {
            '3M'  => '-0.058',
            '12M' => 0,
            '6M'  => '-0.039',
            '9M'  => '-0.02'
        },
        'AUD' => {
            '3M'  => '-0.207',
            '12M' => '-0.167',
            '6M'  => '-0.19',
            '9M'  => '-0.177'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.566',
            '12M' => '-0.379',
            '6M'  => '-0.488',
            '9M'  => '-0.427'
        }
    },
    'N100' => {
        'GBP' => {
            '3M'  => '-0.314',
            '12M' => '-0.257',
            '6M'  => '-0.295',
            '9M'  => '-0.276'
        },
        'AUD' => {
            '3M'  => '-0.208',
            '12M' => '-0.187',
            '6M'  => '-0.2',
            '9M'  => '-0.193'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.702',
            '12M' => '-0.461',
            '6M'  => '-0.602',
            '9M'  => '-0.523'
        }
    },
    'OTC_IBEX35' => {
        'GBP' => {
            '3M'  => '-0.093',
            '12M' => '-0.031',
            '6M'  => '-0.073',
            '9M'  => '-0.052'
        },
        'AUD' => {
            '3M'  => '-0.253',
            '12M' => '-0.162',
            '6M'  => '-0.215',
            '9M'  => '-0.185'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.721',
            '12M' => '-0.455',
            '6M'  => '-0.611',
            '9M'  => '-0.524'
        }
    },
    'OMXS30' => {
        'GBP' => {
            '3M'  => '0.128',
            '12M' => '0.073',
            '6M'  => '0.11',
            '9M'  => '0.091'
        },
        'AUD' => {
            '3M'  => '-0.093',
            '12M' => '-0.072',
            '6M'  => '-0.085',
            '9M'  => '-0.078'
        },
        'EUR' => {
            '3M'  => '-0.321',
            '12M' => '-0.366',
            '6M'  => '-0.34',
            '9M'  => '-0.354'
        },
        'USD' => {
            '3M'  => '-0.293',
            '12M' => '-0.422',
            '6M'  => '-0.347',
            '9M'  => '-0.389'
        }
    },
    'OTC_DJI' => {
        'GBP' => {
            '3M'  => '-0.057',
            '12M' => '-0.103',
            '6M'  => '-0.076',
            '9M'  => '-0.091'
        },
        'AUD' => {
            '3M'  => '-0.025',
            '12M' => '-0.061',
            '6M'  => '-0.04',
            '9M'  => '-0.052'
        },
        'EUR' => {
            '3M'  => '0.097',
            '12M' => '0.077',
            '6M'  => '0.091',
            '9M'  => '0.084'
        },
        'USD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        }
    },
    'SSECOMP' => {
        'GBP' => {
            '3M'  => '-0.112',
            '12M' => '-0.157',
            '6M'  => '-0.131',
            '9M'  => '-0.145'
        },
        'AUD' => {
            '3M'  => '-0.051',
            '12M' => '-0.112',
            '6M'  => '-0.076',
            '9M'  => '-0.096'
        },
        'EUR' => {
            '3M'  => '-0.001',
            '12M' => '0.009',
            '6M'  => '0.002',
            '9M'  => '0.006'
        },
        'USD' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        }
    },
    'OTC_AEX' => {
        'GBP' => {
            '3M'  => '-0.211',
            '12M' => '-0.156',
            '6M'  => '-0.193',
            '9M'  => '-0.174'
        },
        'AUD' => {
            '3M'  => '-0.269',
            '12M' => '-0.264',
            '6M'  => '-0.267',
            '9M'  => '-0.265'
        },
        'EUR' => {
            '3M'  => 0,
            '12M' => 0,
            '6M'  => 0,
            '9M'  => 0
        },
        'USD' => {
            '3M'  => '-0.525',
            '12M' => '-0.364',
            '6M'  => '-0.458',
            '9M'  => '-0.405'
        }}};

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'correlation_matrix',
    {
        correlations  => $corr,
        recorded_date => Date::Utility->new()});

map { BOM::Test::Data::Utility::UnitTestMarketData::create_doc('index', {symbol => $_->symbol, date => Date::Utility->new,}) } @symbols;

my $data = [{
        underlying => 'OTC_AS51',
        bet_type   => 'CALL',
        date_start => 1428458885,
        duration   => 60,
        prob       => '0.52',
    },
    {
        underlying => 'OTC_AS51',
        bet_type   => 'CALL',
        date_start => 1428458885,
        duration   => 30,
        prob       => '0.52',
    },
];

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'OTC_AS51',
    epoch      => 1428458885
});
foreach my $d (@$data) {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => Date::Utility->new($d->{date_start}),
        }) for (qw/USD GBP EUR AUD CHF AUD-USD/);

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_moneyness',
        {
            symbol        => $_->symbol,
            recorded_date => Date::Utility->new($d->{date_start}),
            spot_tick     => Postgres::FeedDB::Spot::Tick->new({epoch => Date::Utility->new($d->{date_start})->epoch, quote => '1.00'})}
    ) for @symbols;

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => Date::Utility->new($d->{date_start}),
            spot_tick     => Postgres::FeedDB::Spot::Tick->new({epoch => Date::Utility->new($d->{date_start})->epoch, quote => '1.00'})}
    ) for qw(frxEURUSD frxAUDUSD frxUSDCHF);

    my $params = {
        bet_type     => $d->{bet_type},
        currency     => 'USD',
        date_start   => $d->{date_start},
        date_pricing => $d->{date_start},
        payout       => 100,
        duration     => $d->{duration} . 'm',
        underlying   => $d->{underlying},
        barrier      => 'S0P',
    };
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'index',
        {
            symbol        => $d->{underlying},
            recorded_date => Date::Utility->new($d->{date_start}),
        });
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'correlation_matrix',
        {
            correlations  => $corr,
            recorded_date => Date::Utility->new($params->{date_start}),
        });

    my $c = produce_contract($params);
    is roundcommon(0.01, $c->theo_probability->amount),  $d->{prob}, 'theo prob checked';
    is roundcommon(0.01, $c->commission_markup->amount), 0.03,       'commission markup checked';
}
