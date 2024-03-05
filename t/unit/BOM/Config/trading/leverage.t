use strict;
use warnings;

use Test::More;
use Test::Deep;
use YAML::XS;

use BOM::Config;

use constant LEVERAGE_KEYS => qw(
    stock_indices forex metals cryptocurrencies
);

my $leverage = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/cfd/leverage/metatrader/default.yml');

subtest 'leverage stock indices' => sub {
    is_deeply($leverage->{stock_indices}, stocks_indices_structure()->{stock_indices}, 'stock indices config structure is correct');
};

subtest 'leverage metals' => sub {
    is_deeply($leverage->{metals}, metals_structure()->{metals}, 'metals config structure is correct');
};

subtest 'leverage crypto' => sub {
    is_deeply($leverage->{cryptocurrencies}, cryptocurrencies_structure()->{cryptocurrencies}, 'cryptocurrencies config structure is correct');
};

subtest 'leverage forex' => sub {
    is_deeply($leverage->{forex}, forex_structure()->{forex}, 'forex config structure is correct');
};

subtest 'validate leverage keys' => sub {
    is(scalar(keys %$leverage), 4, 'correct number of keys in leverage');

    is_deeply([sort keys %$leverage], [sort +LEVERAGE_KEYS], 'name of keys are correct');
};

sub stocks_indices_structure {
    return {
        'stock_indices' => {
            'instruments'  => ['US_30', 'US_100', 'US_500'],
            'display_name' => 'Stock indices',
            'min'          => 1,
            'volume'       => {
                'unit' => 'lot',
                'data' => [{
                        'from'     => '0.1',
                        'leverage' => 300,
                        'to'       => 5
                    },
                    {
                        'to'       => 50,
                        'leverage' => 200,
                        'from'     => '5.1'
                    },
                    {
                        'leverage' => 100,
                        'to'       => 100,
                        'from'     => '50.1'
                    }]
            },
            'max' => 300,
        }};
}

sub cryptocurrencies_structure {
    return {
        'cryptocurrencies' => {
            'display_name' => 'Cryptocurrencies',
            'max'          => 300,
            'volume'       => {
                'unit' => 'lot',
                'data' => [{
                        'from'     => '0.01',
                        'to'       => 1,
                        'leverage' => 300
                    },
                    {
                        'from'     => '1.01',
                        'leverage' => 200,
                        'to'       => 3
                    },
                    {
                        'from'     => '3.01',
                        'to'       => 5,
                        'leverage' => 100
                    },
                    {
                        'leverage' => 50,
                        'to'       => 10,
                        'from'     => '5.01'
                    }]
            },
            'min'         => 1,
            'instruments' => ['BTCUSD', 'ETHUSD'],
        }};
}

sub metals_structure {
    return {
        'metals' => {
            'instruments' => ['XAUUSD', 'XAGUSD'],
            'volume'      => {
                'unit' => 'lot',
                'data' => [{
                        'leverage' => 1000,
                        'to'       => 1,
                        'from'     => '0.01'
                    },
                    {
                        'to'       => 5,
                        'leverage' => 500,
                        'from'     => '1.01'
                    },
                    {
                        'from'     => '5.01',
                        'to'       => 10,
                        'leverage' => 100
                    },
                    {
                        'from'     => '10.01',
                        'to'       => 15,
                        'leverage' => 50
                    }]
            },
            'min'          => 1,
            'max'          => 1000,
            'display_name' => 'Metals'
        },
    };
}

sub forex_structure {
    return {
        'forex' => {
            'volume' => {
                'data' => [{
                        'from'     => '0.01',
                        'to'       => 1,
                        'leverage' => 1500
                    },
                    {
                        'to'       => 5,
                        'leverage' => 1000,
                        'from'     => '1.01'
                    },
                    {
                        'leverage' => 500,
                        'to'       => 10,
                        'from'     => '5.01'
                    },
                    {
                        'from'     => '10.01',
                        'to'       => 15,
                        'leverage' => 100
                    }
                ],
                'unit' => 'lot'
            },
            'min'          => 1,
            'max'          => 1500,
            'display_name' => 'Forex majors',
            'instruments'  => []
        },
    };
}

done_testing;
