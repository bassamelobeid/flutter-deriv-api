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
                'sequence' => 2
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
    is $mt5_obj->server_geolocation()->{sequence}, 2,         'correct server sequence';

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
    ok exists $server->{$server_type}, 'server id exists';
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
                    'sequence' => 1
                }}
        },
        {
            'p01_ts01' => {
                'environment' => 'Deriv-Server',
                'geolocation' => {
                    'location' => 'Ireland',
                    'region'   => 'Europe',
                    'sequence' => 2
                }}
        },
        {
            'p01_ts02' => {
                'environment' => 'Deriv-Server',
                'geolocation' => {
                    'location' => 'South Africa',
                    'region'   => 'Africa',
                    'sequence' => 1
                }}
        },
        {
            'p01_ts03' => {
                'environment' => 'Deriv-Server',
                'geolocation' => {
                    'location' => 'Singapore',
                    'region'   => 'Asia',
                    'sequence' => 1
                }}
        },
        {
            'p01_ts04' => {
                'environment' => 'Deriv-Server',
                'geolocation' => {
                    'location' => 'Frankfurt',
                    'region'   => 'Europe',
                    'sequence' => 1
                },
            },
        },
        {
            'p02_ts02' => {
                'environment' => 'Deriv-Server-02',
                'geolocation' => {
                    'location' => 'South Africa',
                    'region'   => 'Africa',
                    'sequence' => 2
                },
            },
        },
    ];

    cmp_bag($all_servers, $expected_structure, 'Correct structure for servers');

    $mt5_obj = BOM::Config::MT5->new(group_type => 'demo');
    is scalar @{$mt5_obj->servers()}, 1, 'correct number of demo servers';

    $mt5_obj = BOM::Config::MT5->new(group => 'demo\p01_ts01\synthetic\svg_std_usd');
    is scalar @{$mt5_obj->servers()}, 1, 'correct number of demo servers with group';

    $mt5_obj = BOM::Config::MT5->new(group_type => 'real');
    is scalar @{$mt5_obj->servers()}, 5, 'correct number of demo servers retrieved with group_type';

    $mt5_obj = BOM::Config::MT5->new(group => 'real\p01_ts01\synthetic\svg_std_usd');
    is scalar @{$mt5_obj->servers()}, 5, 'correct number of demo servers retrieved with group';
};

subtest 'symmetrical servers' => sub {
    my $mt5webapi           = BOM::Config::mt5_webapi_config();
    my %symmetrical_tracker = ();

    foreach my $account_type (keys %$mt5webapi) {
        next if ref $mt5webapi->{$account_type} ne 'HASH';

        foreach my $srv (keys $mt5webapi->{$account_type}->%*) {
            my $key = sprintf("%s-%s", $account_type, $mt5webapi->{$account_type}{$srv}{geolocation}{region});

            $symmetrical_tracker{$key} = 0 if not defined $symmetrical_tracker{$key};
            $symmetrical_tracker{$key} += 1;
        }
    }

    foreach my $account_type (keys %$mt5webapi) {
        next if ref $mt5webapi->{$account_type} ne 'HASH';

        foreach my $srv (keys $mt5webapi->{$account_type}->%*) {
            my $key         = sprintf("%s-%s", $account_type, $mt5webapi->{$account_type}{$srv}{geolocation}{region});
            my $sym_servers = BOM::Config::MT5->new(
                group_type  => $account_type,
                server_type => $srv
            )->symmetrical_servers();
            my $got      = scalar keys %$sym_servers;
            my $expected = ($account_type eq 'real' and $srv eq 'p01_ts01') ? 1 : $symmetrical_tracker{$key};

            $expected -= 1 if $mt5webapi->{$account_type}{$srv}{geolocation}{region} eq 'Europe' and $srv ne 'p01_ts01';

            is $got, $expected, "${account_type}-${srv}: valid number of symmetrical servers: ${got} (Expected ${expected})";
        }
    }
};

subtest 'server by country' => sub {
    my $mt5      = BOM::Config::MT5->new();
    my $expected = {
        'demo' => {
            'financial' => [{
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'Europe',
                        'location' => 'Ireland'
                    },
                    'supported_accounts' => ['gaming', 'financial', 'financial_stp'],
                    'recommended'        => 1,
                    'id'                 => 'p01_ts01',
                    'disabled'           => 0,
                    'environment'        => 'Deriv-Demo'
                }
            ],
            'synthetic' => [{
                    'environment' => 'Deriv-Demo',
                    'disabled'    => 0,
                    'recommended' => 1,
                    'id'          => 'p01_ts01',
                    'geolocation' => {
                        'sequence' => 1,
                        'region'   => 'Europe',
                        'location' => 'Ireland'
                    },
                    'supported_accounts' => ['gaming', 'financial', 'financial_stp']}]}};
    my $result = $mt5->server_by_country('id', {group_type => 'demo'});
    is_deeply($result, $expected, 'output expected for demo server on Indonesia');

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
            'financial' => [{
                    'environment' => 'Deriv-Server',
                    'disabled'    => 0,
                    'geolocation' => {
                        'sequence' => 2,
                        'region'   => 'Europe',
                        'location' => 'Ireland'
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
                        'location' => 'Singapore'
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
                        'region'   => 'Africa'
                    }
                },
                {
                    'supported_accounts' => ['gaming'],
                    'geolocation'        => {
                        'sequence' => 2,
                        'location' => 'South Africa',
                        'region'   => 'Africa'
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
                        'sequence' => 1
                    },
                    'supported_accounts' => ['gaming'],
                    'recommended'        => 0,
                    'id'                 => 'p01_ts04'
                }]}};

    $result = $mt5->server_by_country('id', {group_type => 'real'});
    is_deeply($result, $expected, 'output expected for real server on Indonesia');
    delete $expected->{real}{financial};

    $result = $mt5->server_by_country(
        'id',
        {
            group_type  => 'real',
            market_type => 'synthetic'
        });
    is_deeply($result, $expected, 'output expected for real synthetic server on Indonesia');
};

done_testing();
