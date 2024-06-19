use strict;
use warnings;

use Test::More;
use Test::Deep;

use BOM::Test::RPC::QueueClient;

my $c = BOM::Test::RPC::QueueClient->new();

subtest 'platform deposit and withdrawal' => sub {

    my $params = {
        language => 'EN',
        args     => {platform => "mt5"},
    };

    my $expected_result = {
        'forex' => {
            'display_name' => 'Forex majors',
            'volume'       => {
                'data' => [{
                        'leverage' => 1500,
                        'from'     => '0.01',
                        'to'       => 1
                    },
                    {
                        'from'     => '1.01',
                        'to'       => 5,
                        'leverage' => 1000
                    },
                    {
                        'to'       => 10,
                        'from'     => '5.01',
                        'leverage' => 500
                    },
                    {
                        'to'       => 15,
                        'from'     => '10.01',
                        'leverage' => 100
                    }
                ],
                'unit' => 'lot'
            },
            'instruments' => [],
            'max'         => 1500,
            'min'         => 1
        },
        'stock_indices' => {
            'min'          => 1,
            'max'          => 300,
            'instruments'  => ['US_30', 'US_100', 'US_500'],
            'display_name' => 'Stock indices',
            'volume'       => {
                'data' => [{
                        'leverage' => 300,
                        'to'       => 5,
                        'from'     => '0.1'
                    },
                    {
                        'leverage' => 200,
                        'from'     => '5.1',
                        'to'       => 50
                    },
                    {
                        'leverage' => 100,
                        'from'     => '50.1',
                        'to'       => 100
                    }
                ],
                'unit' => 'lot'
            }
        },
        'metals' => {
            'min'          => 1,
            'max'          => 1000,
            'instruments'  => ['XAUUSD', 'XAGUSD'],
            'display_name' => 'Metals',
            'volume'       => {
                'data' => [{
                        'to'       => 1,
                        'from'     => '0.01',
                        'leverage' => 1000
                    },
                    {
                        'to'       => 5,
                        'from'     => '1.01',
                        'leverage' => 500
                    },
                    {
                        'leverage' => 100,
                        'from'     => '5.01',
                        'to'       => 10
                    },
                    {
                        'from'     => '10.01',
                        'to'       => 15,
                        'leverage' => 50
                    }
                ],
                'unit' => 'lot'
            }
        },
        'cryptocurrencies' => {
            'min'         => 1,
            'max'         => 300,
            'instruments' => ['BTCUSD', 'ETHUSD'],
            'volume'      => {
                'unit' => 'lot',
                'data' => [{
                        'from'     => '0.01',
                        'to'       => 1,
                        'leverage' => 300
                    },
                    {
                        'from'     => '1.01',
                        'to'       => 3,
                        'leverage' => 200
                    },
                    {
                        'leverage' => 100,
                        'to'       => 5,
                        'from'     => '3.01'
                    },
                    {
                        'from'     => '5.01',
                        'to'       => 10,
                        'leverage' => 50
                    }]
            },
            'display_name' => 'Cryptocurrencies'
        }};

    my $result = $c->call_ok('trading_platform_leverage', $params)->result;

    is_deeply($expected_result, $result->{leverage}, 'Correct structure for the leverage');

};

done_testing;
