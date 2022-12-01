use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;

use BOM::Config::MT5;

subtest 'create server structure' => sub {
    my $mt5_config = BOM::Config::MT5::webapi_config();

    my $structure = BOM::Config::MT5::create_server_structure(server => $mt5_config->{"real"}{"p01_ts01"});
    is $structure, undef, 'undef if server_type is not provided';

    $structure = BOM::Config::MT5::create_server_structure(server_type => 'p01_ts01');
    is $structure, undef, 'undef if server is not provided';

    $structure = BOM::Config::MT5::create_server_structure(
        server_type => 'p01_ts01',
        server      => $mt5_config->{"real"}{"p01_ts01"});

    my $expected_structure = {
        'p01_ts01' => {
            'environment' => 'Deriv-Server',
            'geolocation' => {
                'location' => 'Ireland',
                'region'   => 'Europe',
                'sequence' => 1,
                group      => 'all'
            },
        },
    };

    cmp_deeply($structure, $expected_structure, 'got correct server result structure');
};

subtest 'server geolocation' => sub {
    my $mt5_obj = BOM::Config::MT5->new(
        group_type  => 'real',
        server_type => 'p01_ts05'
    );
    like(
        exception { $mt5_obj->server_geolocation() },
        qr/Cannot extract server information from  server type\[p01_ts05\] and group type\[real\]/,
        'undef if server type is not that we know'
    );

    $mt5_obj = BOM::Config::MT5->new(
        group_type  => 'real',
        server_type => 'p01_ts01'
    );
    is $mt5_obj->server_geolocation()->{region},   'Europe',  'correct server region';
    is $mt5_obj->server_geolocation()->{location}, 'Ireland', 'correct server location';
    is $mt5_obj->server_geolocation()->{sequence}, 1,         'correct server sequence';

    $mt5_obj = BOM::Config::MT5->new(
        group_type  => 'real',
        server_type => 'p01_ts02'
    );
    is $mt5_obj->server_geolocation()->{region},   'Africa',       'correct server region';
    is $mt5_obj->server_geolocation()->{location}, 'South Africa', 'correct server location';
    is $mt5_obj->server_geolocation()->{sequence}, 1,              'correct server sequence';
};

subtest 'server by id' => sub {
    my $mt5_obj = BOM::Config::MT5->new(
        group_type  => 'real',
        server_type => 'sample'
    );
    like(
        exception { $mt5_obj->server_by_id() },
        qr/Cannot extract server information from  server type\[sample\] and group type\[real\]/,
        'undef if server id is not that we know of'
    );

    my $server_type = 'p01_ts01';
    $mt5_obj = BOM::Config::MT5->new(
        group_type  => 'real',
        server_type => $server_type
    );

    my $server = $mt5_obj->server_by_id();
    ok exists $server->{$server_type},              'server id exists';
    ok exists $server->{$server_type}{geolocation}, 'geolocation exists';

    is $server->{$server_type}{geolocation}{region},   'Europe',  'undef if server id is not that we know of';
    is $server->{$server_type}{geolocation}{location}, 'Ireland', 'undef if server id is not that we know of';
};

subtest 'servers' => sub {
    my $mt5_obj     = BOM::Config::MT5->new();
    my $all_servers = $mt5_obj->servers();

    my $expected_structure = [{
            'p01_ts01' => {
                'environment' => 'Deriv-Demo',
                'geolocation' => {
                    'location' => 'Ireland',
                    'region'   => 'Europe',
                    'sequence' => 1,
                    group      => 'all',
                }}
        },
        {
            'p01_ts02' => {
                'environment' => 'Deriv-Demo',
                'geolocation' => {
                    'location' => 'N. Virginia',
                    'region'   => 'US East',
                    'sequence' => 1,
                    group      => 'all',
                }}
        },
        {
            'p01_ts03' => {
                'environment' => 'Deriv-Demo',
                'geolocation' => {
                    'location' => 'Frankfurt',
                    'region'   => 'Europe',
                    'sequence' => 1,
                    group      => 'all',
                }}
        },
        {
            'p01_ts04' => {
                'environment' => 'Deriv-Demo',
                'geolocation' => {
                    'group'    => 'derivez',
                    'location' => 'Frankfurt',
                    'region'   => 'Europe',
                    'sequence' => 1
                }}
        },
        {
            'p01_ts01' => {
                'environment' => 'Deriv-Server',
                'geolocation' => {
                    'location' => 'Ireland',
                    'region'   => 'Europe',
                    'sequence' => 1,
                    group      => 'all',
                }}
        },
        {
            'p01_ts02' => {
                'environment' => 'Deriv-Server',
                'geolocation' => {
                    'location' => 'South Africa',
                    'region'   => 'Africa',
                    'sequence' => 1,
                    group      => 'africa_synthetic',
                }}
        },
        {
            'p01_ts03' => {
                'environment' => 'Deriv-Server',
                'geolocation' => {
                    'location' => 'Singapore',
                    'region'   => 'Asia',
                    'sequence' => 1,
                    group      => 'asia_synthetic',
                }}
        },
        {
            'p01_ts04' => {
                'environment' => 'Deriv-Server',
                'geolocation' => {
                    'location' => 'Frankfurt',
                    'region'   => 'Europe',
                    'sequence' => 1,
                    group      => 'europe_synthetic',
                },
            },
        },
        {
            'p02_ts01' => {
                'environment' => 'Deriv-Server-02',
                'geolocation' => {
                    'group'    => 'africa_derivez',
                    'location' => 'South Africa',
                    'region'   => 'Africa',
                    'sequence' => 2
                }}
        },
        {
            'p02_ts02' => {
                'environment' => 'Deriv-Server-02',
                'geolocation' => {
                    'location' => 'South Africa',
                    'region'   => 'Africa',
                    'sequence' => 2,
                    'group'    => 'africa_synthetic',
                },
            },
        },
    ];

    cmp_bag($all_servers, $expected_structure, 'Correct structure for servers');

    $mt5_obj = BOM::Config::MT5->new(group_type => 'demo');
    is scalar @{$mt5_obj->servers()}, 4, 'correct number of demo servers';

    $mt5_obj = BOM::Config::MT5->new(group => 'demo\p01_ts01\synthetic\svg_std_usd');
    is scalar @{$mt5_obj->servers()}, 4, 'correct number of demo servers with group';

    $mt5_obj = BOM::Config::MT5->new(group_type => 'real');
    is scalar @{$mt5_obj->servers()}, 6, 'correct number of demo servers retrieved with group_type';

    $mt5_obj = BOM::Config::MT5->new(group => 'real\p01_ts01\synthetic\svg_std_usd');
    is scalar @{$mt5_obj->servers()}, 6, 'correct number of demo servers retrieved with group';
};

subtest 'symmetrical servers' => sub {
    my $mt5webapi           = BOM::Config::mt5_webapi_config();
    my %symmetrical_tracker = ();

    foreach my $account_type (keys %$mt5webapi) {
        next if ref $mt5webapi->{$account_type} ne 'HASH';

        foreach my $srv (keys $mt5webapi->{$account_type}->%*) {
            my $key = sprintf("%s-%s", $account_type, $mt5webapi->{$account_type}{$srv}{geolocation}{group});

            $symmetrical_tracker{$key} = 0 if not defined $symmetrical_tracker{$key};
            $symmetrical_tracker{$key} += 1;
        }
    }

    foreach my $account_type (keys %$mt5webapi) {
        next if ref $mt5webapi->{$account_type} ne 'HASH';

        foreach my $srv (keys $mt5webapi->{$account_type}->%*) {
            my $key         = sprintf("%s-%s", $account_type, $mt5webapi->{$account_type}{$srv}{geolocation}{group});
            my $sym_servers = BOM::Config::MT5->new(
                group_type  => $account_type,
                server_type => $srv
            )->symmetrical_servers();
            my $got      = scalar keys %$sym_servers;
            my $expected = ($account_type eq 'real' and $srv eq 'p01_ts01') ? 1 : $symmetrical_tracker{$key};

            is $got, $expected, "${account_type}-${srv}: valid number of symmetrical servers: ${got} (Expected ${expected})";
        }
    }
};

subtest 'server by country' => sub {
    my $mt5      = BOM::Config::MT5->new();
    my $expected = {
        'demo' => {
            'all' => [{
                    'geolocation' => {
                        'group'    => 'derivez',
                        'location' => 'Frankfurt',
                        'region'   => 'Europe',
                        'sequence' => 1
                    },
                    'supported_accounts' => ['all'],
                    'recommended'        => 1,
                    'id'                 => 'p01_ts04',
                    'disabled'           => 0,
                    'environment'        => 'Deriv-Demo',
                },
            ],
            'financial' => [{
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'Europe',
                        'location' => 'Ireland',
                        group      => 'all',
                    },
                    'supported_accounts' => ['gaming', 'financial', 'financial_stp'],
                    'recommended'        => 1,
                    'id'                 => 'p01_ts01',
                    'disabled'           => 0,
                    'environment'        => 'Deriv-Demo'
                },
                {
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'Europe',
                        'location' => 'Frankfurt',
                        group      => 'all',
                    },
                    'supported_accounts' => ['gaming', 'financial', 'financial_stp'],
                    'recommended'        => 0,
                    'id'                 => 'p01_ts03',
                    'disabled'           => 0,
                    'environment'        => 'Deriv-Demo'
                },
                {
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'US East',
                        'location' => 'N. Virginia',
                        group      => 'all',
                    },
                    'supported_accounts' => ['gaming', 'financial', 'financial_stp'],
                    'recommended'        => 0,
                    'id'                 => 'p01_ts02',
                    'disabled'           => 0,
                    'environment'        => 'Deriv-Demo'
                },
            ],
            'synthetic' => [{
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'Europe',
                        'location' => 'Ireland',
                        group      => 'all',
                    },
                    'supported_accounts' => ['gaming', 'financial', 'financial_stp'],
                    'recommended'        => 1,
                    'id'                 => 'p01_ts01',
                    'disabled'           => 0,
                    'environment'        => 'Deriv-Demo',
                },
                {
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'Europe',
                        'location' => 'Frankfurt',
                        group      => 'all',
                    },
                    'supported_accounts' => ['gaming', 'financial', 'financial_stp'],
                    'recommended'        => 0,
                    'id'                 => 'p01_ts03',
                    'disabled'           => 0,
                    'environment'        => 'Deriv-Demo'
                },
                {
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'US East',
                        'location' => 'N. Virginia',
                        group      => 'all',
                    },
                    'supported_accounts' => ['gaming', 'financial', 'financial_stp'],
                    'recommended'        => 0,
                    'id'                 => 'p01_ts02',
                    'disabled'           => 0,
                    'environment'        => 'Deriv-Demo'
                }]}};
    my $result = $mt5->server_by_country('id', {group_type => 'demo'});

    is_deeply($result, $expected, 'output expected for demo server on Indonesia');

    $result = $mt5->server_by_country(
        'id',
        {
            group_type  => 'demo',
            market_type => 'all'
        });
    is_deeply($result->{demo}{all}, $expected->{demo}{all}, 'output expected for demo derivez server on Indonesia');

    delete $expected->{demo}{all};
    delete $expected->{demo}{financial};
    $result = $mt5->server_by_country(
        'id',
        {
            group_type  => 'demo',
            market_type => 'synthetic'
        });

    is_deeply($result, $expected, 'output expected for demo synthetic server on Indonesia');
    $expected = {
        'real' => {
            'all' => [{
                    'disabled'    => 0,
                    'environment' => 'Deriv-Server-02',
                    'geolocation' => {
                        'group'    => 'africa_derivez',
                        'location' => 'South Africa',
                        'region'   => 'Africa',
                        'sequence' => 2
                    },
                    'id'                 => 'p02_ts01',
                    'recommended'        => 1,
                    'supported_accounts' => ['all']
                },
            ],
            'financial' => [{
                    'environment' => 'Deriv-Server',
                    'disabled'    => 0,
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'Europe',
                        'location' => 'Ireland',
                        group      => 'all',
                    },
                    'supported_accounts' => ['gaming', 'financial', 'financial_stp'],
                    'recommended'        => 1,
                    'id'                 => 'p01_ts01'
                }
            ],
            'synthetic' => [{
                    'recommended' => 1,
                    'id'          => 'p01_ts03',
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'Asia',
                        'location' => 'Singapore',
                        group      => 'asia_synthetic'
                    },
                    'supported_accounts' => ['gaming'],
                    'environment'        => 'Deriv-Server',
                    'disabled'           => 0
                },
                {
                    'disabled'           => 0,
                    'environment'        => 'Deriv-Server',
                    'recommended'        => 0,
                    'id'                 => 'p01_ts02',
                    'supported_accounts' => ['gaming'],
                    'geolocation'        => {
                        'sequence' => 1,
                        'location' => 'South Africa',
                        'region'   => 'Africa',
                        group      => 'africa_synthetic'
                    }
                },
                {
                    'supported_accounts' => ['gaming'],
                    'geolocation'        => {
                        'sequence' => 2,
                        'location' => 'South Africa',
                        'region'   => 'Africa',
                        group      => 'africa_synthetic'
                    },
                    'id'          => 'p02_ts02',
                    'recommended' => 0,
                    'disabled'    => 1,
                    'environment' => 'Deriv-Server-02'
                },
                {
                    'environment' => 'Deriv-Server',
                    'disabled'    => 0,
                    'geolocation' => {
                        'region'   => 'Europe',
                        'location' => 'Frankfurt',
                        'sequence' => 1,
                        group      => 'europe_synthetic'
                    },
                    'supported_accounts' => ['gaming'],
                    'recommended'        => 0,
                    'id'                 => 'p01_ts04'
                }]}};

    $result = $mt5->server_by_country('id', {group_type => 'real'});

    is_deeply($result, $expected, 'output expected for real server on Indonesia');

    $result = $mt5->server_by_country(
        'id',
        {
            group_type  => 'real',
            market_type => 'all'
        });

    is_deeply($result->{real}{all}, $expected->{real}{all}, 'output expected for demo derivez server on Indonesia');

    delete $expected->{real}{all};
    delete $expected->{real}{financial};
    $result = $mt5->server_by_country(
        'id',
        {
            group_type  => 'real',
            market_type => 'synthetic'
        });
    is_deeply($result, $expected, 'output expected for real synthetic server on Indonesia');
};

subtest 'available_groups' => sub {
    my $mt5_config = BOM::Config::MT5->new;
    # we should test the:
    # - filtering logic
    # - total group per landing company
    my @test_cases = ({
            filter  => {server_type => 'real'},
            count   => 86,
            comment => 'real groups'
        },
        {
            filter  => {server_type => 'demo'},
            count   => 28,
            comment => 'demo groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'svg'
            },
            count   => 41,
            comment => 'real svg groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'svg',
                market_type => 'financial'
            },
            count   => 13,
            comment => 'real svg financial groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'svg',
                market_type => 'synthetic'
            },
            count   => 25,
            comment => 'real svg synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'svg'
            },
            count   => 10,
            comment => 'demo svg groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'svg',
                market_type => 'financial'
            },
            count   => 6,
            comment => 'demo svg financial groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'svg',
                market_type => 'synthetic'
            },
            count   => 3,
            comment => 'demo svg synthetic groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'malta'
            },
            count   => 0,
            comment => 'real malta groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'malta',
                market_type => 'financial'
            },
            count   => 0,
            comment => 'real malta financial groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'malta',
                market_type => 'synthetic'
            },
            count   => 0,
            comment => 'real malta synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'malta'
            },
            count   => 0,
            comment => 'demo malta groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'malta',
                market_type => 'financial'
            },
            count   => 0,
            comment => 'demo malta financial groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'malta',
                market_type => 'synthetic'
            },
            count   => 0,
            comment => 'demo malta synthetic groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'maltainvest'
            },
            allow_multiple_subgroups => 1,
            count                    => 15,
            comment                  => 'real maltainvest groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'maltainvest',
                market_type => 'financial'
            },
            allow_multiple_subgroups => 1,
            count                    => 15,
            comment                  => 'real maltainvest financial groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'maltainvest',
                market_type => 'synthetic'
            },
            allow_multiple_subgroups => 1,
            count                    => 0,
            comment                  => 'real maltainvest synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'maltainvest'
            },
            allow_multiple_subgroups => 1,
            count                    => 7,
            comment                  => 'demo maltainvest groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'maltainvest',
                market_type => 'financial'
            },
            allow_multiple_subgroups => 1,
            count                    => 7,
            comment                  => 'demo maltainvest financial groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'maltainvest',
                market_type => 'synthetic'
            },
            allow_multiple_subgroups => 1,
            count                    => 0,
            comment                  => 'demo maltainvest synthetic groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'iom'
            },
            count   => 0,
            comment => 'real iom groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'iom',
                market_type => 'financial'
            },
            count   => 0,
            comment => 'real iom financial groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'iom',
                market_type => 'synthetic'
            },
            count   => 0,
            comment => 'real iom synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'iom'
            },
            count   => 0,
            comment => 'demo iom groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'iom',
                market_type => 'financial'
            },
            count   => 0,
            comment => 'demo iom financial groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'iom',
                market_type => 'synthetic'
            },
            count   => 0,
            comment => 'demo iom synthetic groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'bvi'
            },
            count   => 19,
            comment => 'real bvi groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'bvi',
                market_type => 'financial'
            },
            count   => 9,
            comment => 'real bvi financial groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'bvi',
                market_type => 'synthetic'
            },
            count   => 10,
            comment => 'real bvi synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'bvi'
            },
            count   => 5,
            comment => 'demo bvi groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'bvi',
                market_type => 'financial'
            },
            count   => 3,
            comment => 'demo bvi financial groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'bvi',
                market_type => 'synthetic'
            },
            count   => 2,
            comment => 'demo bvi synthetic groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'vanuatu'
            },
            allow_multiple_subgroups => 1,
            count                    => 1,
            comment                  => 'real vanuatu groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'vanuatu',
                market_type => 'financial'
            },
            allow_multiple_subgroups => 1,
            count                    => 1,
            comment                  => 'real vanuatu financial groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'vanuatu',
                market_type => 'synthetic'
            },
            count   => 0,
            comment => 'real vanuatu synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'vanuatu'
            },
            count   => 3,
            comment => 'demo vanuatu groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'vanuatu',
                market_type => 'financial'
            },
            count   => 3,
            comment => 'demo vanuatu financial groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'vanuatu',
                market_type => 'synthetic'
            },
            count   => 0,
            comment => 'demo vanuatu synthetic groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'labuan'
            },
            count   => 5,
            comment => 'real labuan groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'labuan',
                market_type => 'financial'
            },
            count   => 5,
            comment => 'real labuan financial groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'labuan',
                market_type => 'synthetic'
            },
            count   => 0,
            comment => 'real labuan synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'labuan'
            },
            count   => 3,
            comment => 'demo labuan groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'labuan',
                market_type => 'financial'
            },
            count   => 3,
            comment => 'demo labuan financial groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'labuan',
                market_type => 'synthetic'
            },
            count   => 0,
            comment => 'demo labuan synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'svg',
                market_type => 'all'
            },
            count   => 1,
            comment => 'demo svg derivez groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'svg',
                market_type => 'all'
            },
            count   => 3,
            comment => 'real svg derivez groups'
        },

    );

    foreach my $test (@test_cases) {
        is $mt5_config->available_groups($test->{filter}, $test->{allow_multiple_subgroups}), $test->{count}, $test->{comment};
    }
};

done_testing();
