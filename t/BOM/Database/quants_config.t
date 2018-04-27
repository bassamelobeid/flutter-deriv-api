#!/usr/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use Quant::Framework::Underlying;
use BOM::Database::QuantsConfig;
use JSON::MaybeXS;

use Test::Deep;
use Test::More;
use Test::Exception;
use Test::FailWarnings;
use Test::MockModule;

my $json = JSON::MaybeXS->new;

my $qc = BOM::Database::QuantsConfig->new();

subtest 'exception check for set_global_limit' => sub {
    throws_ok { $qc->set_global_limit() } qr/limit_type not specified/, 'throws error if limit_type is not undefined';
    throws_ok { $qc->set_global_limit({limit_type => 'unknown', limit_amount => 10}) } qr/limit_type is not supported/,
        'throws error if limit_type is unknown';
    throws_ok { $qc->set_global_limit({limit_type => 'global_potential_loss'}) } qr/limit_amount not specified/,
        'throws error if limit_amount is not defined';
    throws_ok { $qc->set_global_limit({limit_type => 'global_potential_loss'}) } qr/limit_amount not specified/,
        'throws error if limit_amount is not defined';
    throws_ok { $qc->set_global_limit({limit_type => 'global_potential_loss', limit_amount => -1}) } qr/limit_amount must be a positive number/,
        'throws error if limit_amount is not a positive number';
    throws_ok { $qc->set_global_limit({limit_type => 'global_potential_loss', limit_amount => 'test'}) } qr/limit_amount must be a positive number/,
        'throws error if limit_amount is not a positive number';
    throws_ok {
        $qc->set_global_limit({
                limit_type        => 'global_potential_loss',
                limit_amount      => 10,
                underlying_symbol => ['frxUSDJPY'],
                market            => ['forex', 'indices']})
    }
    qr/If you select multiple markets, underlying symbol can only be default/,
        'throws error if both underlying_symbol and market are specified for a single entry';
    throws_ok {
        $qc->set_global_limit({
                limit_type        => 'global_potential_loss',
                limit_amount      => 10,
                underlying_symbol => ['frxUSDJPY'],
            })
    }
    qr/Please specify the market of the underlying symbol input/, 'throws error if market is not specified but underlying symbol is specified';
};

subtest 'set global' => sub {
    my @set_test_cases = ({
            limit_type   => 'global_potential_loss',
            limit_amount => 110,
        },
        {
            limit_type   => 'global_potential_loss',
            limit_amount => 109,
            market       => ['forex', 'volidx'],
        },
        {
            limit_type        => 'global_potential_loss',
            limit_amount      => 108,
            market            => ['forex'],
            underlying_symbol => ['frxUSDJPY'],
        },
        {
            limit_type        => 'global_potential_loss',
            limit_amount      => 111,
            market            => ['forex'],
            underlying_symbol => ['default'],
        },
        {
            limit_type   => 'global_potential_loss',
            limit_amount => 107,
            expiry_type  => ['intraday'],
        },
        {
            limit_type        => 'global_potential_loss',
            limit_amount      => 100,
            market            => ['forex'],
            underlying_symbol => ['frxAUDJPY'],
            expiry_type       => ['intraday'],
        },
        {
            limit_type        => 'global_potential_loss',
            limit_amount      => 106,
            market            => ['forex'],
            underlying_symbol => ['frxUSDJPY'],
            expiry_type       => ['intraday'],
        },
        {
            limit_type   => 'global_potential_loss',
            limit_amount => 105,
            expiry_type  => ['tick'],
            barrier_type => ['atm'],
        },
        {
            limit_type     => 'global_potential_loss',
            limit_amount   => 104,
            expiry_type    => ['daily', 'intraday'],
            barrier_type   => ['non_atm'],
            contract_group => ['callput'],
        },
        {
            limit_type      => 'global_potential_loss',
            limit_amount    => 103,
            expiry_type     => ['daily', 'intraday'],
            barrier_type    => ['non_atm'],
            contract_group  => ['callput'],
            landing_company => ['costarica'],
        },
    );
    foreach my $t (@set_test_cases) {
        lives_ok { $qc->set_global_limit($t) } 'limit save for ' . $json->encode($t);
    }

};

subtest 'exception for get_global_limit' => sub {
    throws_ok { $qc->get_global_limit() } qr/landing_company is undefined/, 'throws exception if landing_company is not specified';
    throws_ok { $qc->get_global_limit({landing_company => 'costarica'}) } qr/limit_type is undefined/,
        'throws exception if limit_type is not specified';
    throws_ok { $qc->get_global_limit({landing_company => 'costarica', limit_type => 'unknown'}) } qr/unsupported limit type/,
        'throws exception if limit_type is not supported';
    lives_ok {
        $qc->get_global_limit({
                landing_company => 'costarica',
                limit_type      => 'global_potential_loss',
            })
    };

};

subtest 'get global limit' => sub {
    my @test_cases = ([{
                market         => 'indices',
                expiry_type    => 'intraday',
                barrier_type   => 'atm',
                contract_group => 'callput',
                limit_type     => 'global_potential_loss'
            },
            107
        ],
        [{
                market         => 'volidx',
                expiry_type    => 'tick',
                barrier_type   => 'atm',
                contract_group => 'callput',
                limit_type     => 'global_potential_loss',
            },
            105
        ],
        [{
                market         => 'volidx',
                expiry_type    => 'tick',
                contract_group => 'callput',
                limit_type     => 'global_potential_loss',
            },
            109
        ],
        [{
                underlying_symbol => 'frxUSDJPY',
                market            => 'forex',
                expiry_type       => 'daily',
                barrier_type      => 'non_atm',
                contract_group    => 'touchnotouch',
                limit_type        => 'global_potential_loss',
            },
            108
        ],
        [{
                market         => 'forex',
                expiry_type    => 'daily',
                barrier_type   => 'non_atm',
                contract_group => 'callput',
                limit_type     => 'global_potential_loss',
            },
            103
        ],
        [{
                limit_type => 'global_potential_loss',
            },
            110
        ],
        [{
                market            => 'forex',
                underlying_symbol => 'frxAUDUSD',
                limit_type        => 'global_potential_loss',
            },
            111
        ],
        [{
                underlying_symbol => 'frxUSDJPY',
                expiry_type       => 'intraday',
                limit_type        => 'global_potential_loss',
            },
            106
        ],
        [{
                underlying_symbol => 'frxUSDJPY',
                limit_type        => 'global_potential_loss',
            },
            108
        ],
        [{
                underlying_symbol => 'frxAUDJPY',
                expiry_type       => 'intraday',
                limit_type        => 'global_potential_loss',
            },
            100
        ],
    );
    foreach my $t (@test_cases) {
        my %input = %{$t->[0]};
        $input{landing_company} = 'costarica';
        is $qc->get_global_limit(\%input), $t->[1], 'expected limit amount received for ' . $json->encode($t->[0]);
    }
};

subtest 'get all global limit' => sub {
    my $mocked = Test::MockModule->new('BOM::Database::QuantsConfig');
    $mocked->mock(
        '_get_all',
        sub {
            my ($self, $landing_company) = @_;
            my $test_data = {
                costarica => {
                    '1fbade408efc3d8b' => {
                        'barrier_type'          => 'default',
                        'contract_group'        => 'default',
                        'expiry_type'           => 'default',
                        'global_potential_loss' => 201,
                        'global_realized_loss'  => 100000,
                        'market'                => 'forex',
                        'type'                  => 'market',
                        'underlying_symbol'     => '-',
                    },
                    '30e1a394a193b321' => {
                        'barrier_type'          => 'default',
                        'contract_group'        => 'default',
                        'expiry_type'           => 'default',
                        'global_potential_loss' => 20000,
                        'global_realized_loss'  => 10000,
                        'market'                => 'commodities',
                        'type'                  => 'symbol_default',
                        'underlying_symbol'     => 'default',
                    }
                },
                virtual => {
                    '1fbade408efc3d8b' => {
                        'barrier_type'          => 'default',
                        'contract_group'        => 'default',
                        'expiry_type'           => 'default',
                        'global_potential_loss' => 201,
                        'global_realized_loss'  => 100000,
                        'market'                => 'forex',
                        'type'                  => 'market',
                        'underlying_symbol'     => '-',
                    },
                    '30e1a394a193b321' => {
                        'barrier_type'          => 'default',
                        'contract_group'        => 'default',
                        'expiry_type'           => 'default',
                        'global_potential_loss' => 20000,
                        'global_realized_loss'  => 10000,
                        'market'                => 'commodities',
                        'type'                  => 'symbol_default',
                        'underlying_symbol'     => 'default',
                    },
                    '6bf6326690bd1009' => {
                        'barrier_type'          => 'default',
                        'contract_group'        => 'default',
                        'expiry_type'           => 'default',
                        'global_potential_loss' => 400000,
                        'global_realized_loss'  => 200000,
                        'market'                => 'volidx',
                        'type'                  => 'market',
                        'underlying_symbol'     => '-',
                    },
                },
            };
            return $test_data->{$landing_company};
        });
    my $qc       = BOM::Database::QuantsConfig->new;
    my $config   = $qc->get_all_global_limit(['costarica', 'virtual']);
    my $expected = [{
            'barrier_type'          => 'default',
            'contract_group'        => 'default',
            'expiry_type'           => 'default',
            'global_potential_loss' => 201,
            'global_realized_loss'  => 100000,
            'market'                => 'forex',
            'type'                  => 'market',
            'underlying_symbol'     => '-',
            'landing_company'       => 'default',
        },
        {
            'barrier_type'          => 'default',
            'contract_group'        => 'default',
            'expiry_type'           => 'default',
            'global_potential_loss' => 20000,
            'global_realized_loss'  => 10000,
            'market'                => 'commodities',
            'type'                  => 'symbol_default',
            'underlying_symbol'     => 'default',
            'landing_company'       => 'default',
        },
        {
            'barrier_type'          => 'default',
            'contract_group'        => 'default',
            'expiry_type'           => 'default',
            'global_potential_loss' => 400000,
            'global_realized_loss'  => 200000,
            'market'                => 'volidx',
            'type'                  => 'market',
            'underlying_symbol'     => '-',
            'landing_company'       => 'virtual',
        },
    ];
    cmp_bag($config, $expected, 'get all config in the correct format');
    $mocked->unmock_all();
};

subtest 'delete global limit' => sub {
    ok $qc->get_global_limit({
            landing_company => 'costarica',
            limit_type      => 'global_potential_loss'
        }
        ),
        'limit fetched';
    lives_ok { $qc->delete_global_limit({type => 'market', landing_company => 'costarica', limit_type => 'global_potential_loss'}) } 'delete ok';
    ok !$qc->get_global_limit({
            landing_company => 'costarica',
            limit_type      => 'global_potential_loss'
        }
        ),
        'deleted';
};

my $client  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
my %client_map = (
    $client->loginid  => $client,
    $client2->loginid => $client2,
);

subtest 'set per client limit' => sub {
    SKIP: {
        skip 'per client limit is not turned on', 4 unless %{$qc->supported_config_type->{per_client}};
        my @test_cases = ({
                limit_type   => 'per_client_maximum_payout',
                limit_amount => 110,
                client_id    => ['default'],
            },
            {
                limit_type   => 'per_client_maximum_payout',
                limit_amount => 109,
                market       => ['forex', 'volidx'],
                client_id    => ['default'],
            },
            {
                limit_type        => 'per_client_maximum_payout',
                limit_amount      => 108,
                market            => ['forex'],
                underlying_symbol => ['frxUSDJPY'],
                client_id         => ['default'],
            },
            {
                limit_type        => 'per_client_maximum_payout',
                limit_amount      => 107,
                market            => ['forex'],
                underlying_symbol => ['frxUSDJPY'],
                client_id         => [$client->loginid],
            },
        );

        foreach my $t (@test_cases) {
            lives_ok { $qc->set_global_limit($t) } 'limit save for ' . $json->encode($t);
        }
    }
};

subtest 'get per client limit' => sub {
    SKIP: {
        skip 'per client limit is not turned on', 5 unless %{$qc->supported_config_type->{per_client}};
        my @test_cases = ([{
                    limit_type        => 'per_client_maximum_payout',
                    barrier_type      => 'atm',
                    expiry_type       => 'intraday',
                    contract_type     => 'CALL',
                    underlying_symbol => 'frxAUDJPY',
                    market            => 'forex',
                    client            => $client2->loginid,
                },
                109
            ],
            [{
                    limit_type        => 'per_client_maximum_payout',
                    barrier_type      => 'atm',
                    expiry_type       => 'intraday',
                    contract_type     => 'CALL',
                    underlying_symbol => 'AS51',
                    market            => 'indices',
                    client            => $client2->loginid,
                },
                110
            ],
            [{
                    limit_type        => 'per_client_maximum_payout',
                    barrier_type      => 'atm',
                    expiry_type       => 'intraday',
                    contract_type     => 'CALL',
                    underlying_symbol => 'frxUSDJPY',
                    market            => 'forex',
                    client            => $client->loginid,
                },
                107
            ],
            [{
                    limit_type        => 'per_client_maximum_payout',
                    barrier_type      => 'atm',
                    expiry_type       => 'intraday',
                    contract_type     => 'CALL',
                    underlying_symbol => 'frxUSDJPY',
                    market            => 'forex',
                    client            => $client2->loginid,
                },
                108
            ],
            [{
                    limit_type        => 'per_client_maximum_payout',
                    barrier_type      => 'atm',
                    expiry_type       => 'intraday',
                    contract_type     => 'CALL',
                    underlying_symbol => 'R_100',
                    market            => 'volidx',
                    client            => $client2->loginid,
                },
                109
            ],
        );

        foreach my $t (@test_cases) {
            my $obj = $client_map{$t->[0]->{client}};
            is $qc->get_per_client_limit({%{$t->[0]}, client => $obj}), $t->[1], 'expected limit amount received for ' . $json->encode($t->[0]);
        }
    }
};

done_testing();
