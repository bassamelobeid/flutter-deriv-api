use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;

use BOM::Config::MT5;
use BOM::Config::Runtime;

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

subtest 'server name by landing company' => sub {

    my $server_type = 'p01_ts01';

    my $mt5_obj = BOM::Config::MT5->new(
        group_type  => 'real',
        server_type => $server_type
    );

    my $group_details = {
        account_type          => 'real',
        landing_company_short => 'svg',
    };

    my $result = $mt5_obj->server_name_by_landing_company($group_details);
    is $result, 'DerivSVG-Server', 'correct server name for svg real';

    $group_details = {
        account_type          => 'real',
        landing_company_short => 'maltainvest',
    };

    $result = $mt5_obj->server_name_by_landing_company($group_details);
    is $result, 'DerivMT-Server', 'correct server name for maltainvest real';

    $group_details = {
        account_type          => 'demo',
        landing_company_short => 'svg',
    };

    $result = $mt5_obj->server_name_by_landing_company($group_details);
    is $result, 'Deriv-Server', 'correct server name for svg demo';

    $server_type = 'p02_ts01';
    $mt5_obj     = BOM::Config::MT5->new(
        group_type  => 'real',
        server_type => $server_type
    );

    $group_details = {
        account_type          => 'real',
        landing_company_short => 'bvi',
    };

    $result = $mt5_obj->server_name_by_landing_company($group_details);
    is $result, 'DerivBVI-Server-02', 'correct server name for bvi real';

};

subtest 'white label config for prod' => sub {

    my $mt5_obj        = BOM::Config::MT5->new();
    my $mt5_app_config = BOM::Config::Runtime->instance->app_config->system->mt5;

    my $stage = 'prod';

    my %landing_companies = (
        'Deriv (SVG) LLC' => {
            webtrader_url => 'https://mt5-real[platform]-web-svg.deriv.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivSVG-Demo,DerivSVG-Server,DerivSVG-Server-02,DerivSVG-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivSVG-Demo,DerivSVG-Server,DerivSVG-Server-02,DerivSVG-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22698/mt5/derivsvg5setup.exe',
        },
        'Deriv (BVI) Ltd.' => {
            webtrader_url => 'https://mt5-real[platform]-web-bvi.deriv.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivBVI-Demo,DerivBVI-Server,DerivBVI-Server-02,DerivBVI-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivBVI-Demo,DerivBVI-Server,DerivBVI-Server-02,DerivBVI-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22631/mt5/derivbvi5setup.exe',
        },
        'Deriv Investments (Europe) Limited' => {
            webtrader_url => 'https://mt5-real[platform]-web-mt.deriv.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivMT-Demo,DerivMT-Server,DerivMT-Server-02,DerivMT-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivMT-Demo,DerivMT-Server,DerivMT-Server-02,DerivMT-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22632/mt5/derivmt5setup.exe',
        },
        'Deriv (FX) Ltd' => {
            webtrader_url => 'https://mt5-real[platform]-web-fx.deriv.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivFX-Demo,DerivFX-Server,DerivFX-Server-02,DerivFX-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivFX-Demo,DerivFX-Server,DerivFX-Server-02,DerivFX-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22680/mt5/derivfx5setup.exe',
        },
        'Deriv (V) Ltd' => {
            webtrader_url => 'https://mt5-real[platform]-web-vu.deriv.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivVU-Demo,DerivVU-Server,DerivVU-Server-02,DerivVU-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivVU-Demo,DerivVU-Server,DerivVU-Server-02,DerivVU-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22628/mt5/derivvu5setup.exe',
        },
        'Deriv.com Limited' => {
            webtrader_url => 'https://mt5-demo-web.deriv.com/terminal',
            android       => 'https://download.mql5.com/cdn/mobile/mt5/android?server=Deriv-Demo,Deriv-Server,Deriv-Server-02,Deriv-Server-03',
            ios           => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=Deriv-Demo,Deriv-Server,Deriv-Server-02,Deriv-Server-03',
            windows       => 'https://download.mql5.com/cdn/web/deriv.com.limited/mt5/deriv5setup.exe',
        },
    );

    my @platforms = ('01', '02', '03');

    # Iterate over the landing companies and platforms
    for my $landing_company (keys %landing_companies) {
        for my $platform (@platforms) {

            my $white_label_links = $mt5_obj->white_label_config($mt5_app_config, $landing_company, $platform, $stage);

            # Test that the URLs are the expected URLs
            for my $link_type (keys %{$landing_companies{$landing_company}}) {
                my $expected_url = $landing_companies{$landing_company}{$link_type};
                $expected_url =~ s/\[platform\]/$platform/g;
                is($white_label_links->$link_type, $expected_url, "$link_type is correct for $landing_company platform $platform");
            }
        }
    }

};

subtest 'white label config for dev' => sub {

    my $mt5_obj        = BOM::Config::MT5->new();
    my $mt5_app_config = BOM::Config::Runtime->instance->app_config->system->mt5;

    my $stage = 'dev';

    my %landing_companies = (
        'Deriv (SVG) LLC' => {
            webtrader_url => 'https://mt5-dev-real[platform]-web-svg.regentmarkets.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivSVG-Demo,DerivSVG-Server,DerivSVG-Server-02,DerivSVG-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivSVG-Demo,DerivSVG-Server,DerivSVG-Server-02,DerivSVG-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22698/mt5/derivsvg5setup.exe',
        },
        'Deriv (BVI) Ltd.' => {
            webtrader_url => 'https://mt5-dev-real[platform]-web-bvi.regentmarkets.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivBVI-Demo,DerivBVI-Server,DerivBVI-Server-02,DerivBVI-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivBVI-Demo,DerivBVI-Server,DerivBVI-Server-02,DerivBVI-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22631/mt5/derivbvi5setup.exe',
        },
        'Deriv Investments (Europe) Limited' => {
            webtrader_url => 'https://mt5-dev-real[platform]-web-mt.regentmarkets.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivMT-Demo,DerivMT-Server,DerivMT-Server-02,DerivMT-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivMT-Demo,DerivMT-Server,DerivMT-Server-02,DerivMT-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22632/mt5/derivmt5setup.exe',
        },
        'Deriv (FX) Ltd' => {
            webtrader_url => 'https://mt5-dev-real[platform]-web-fx.regentmarkets.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivFX-Demo,DerivFX-Server,DerivFX-Server-02,DerivFX-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivFX-Demo,DerivFX-Server,DerivFX-Server-02,DerivFX-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22680/mt5/derivfx5setup.exe',
        },
        'Deriv (V) Ltd' => {
            webtrader_url => 'https://mt5-dev-real[platform]-web-vu.regentmarkets.com/terminal',
            android => 'https://download.mql5.com/cdn/mobile/mt5/android?server=DerivVU-Demo,DerivVU-Server,DerivVU-Server-02,DerivVU-Server-03',
            ios     => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=DerivVU-Demo,DerivVU-Server,DerivVU-Server-02,DerivVU-Server-03',
            windows => 'https://download.mql5.com/cdn/web/22628/mt5/derivvu5setup.exe',
        },
        'Deriv.com Limited' => {
            webtrader_url => 'https://mt5-dev-demo-web.regentmarkets.com/terminal',
            android       => 'https://download.mql5.com/cdn/mobile/mt5/android?server=Deriv-Demo,Deriv-Server,Deriv-Server-02,Deriv-Server-03',
            ios           => 'https://download.mql5.com/cdn/mobile/mt5/ios?server=Deriv-Demo,Deriv-Server,Deriv-Server-02,Deriv-Server-03',
            windows       => 'https://download.mql5.com/cdn/web/deriv.com.limited/mt5/deriv5setup.exe',
        },
    );

    my @platforms = ('01', '02', '03');

    # Iterate over the landing companies and platforms
    for my $landing_company (keys %landing_companies) {
        for my $platform (@platforms) {

            my $white_label_links = $mt5_obj->white_label_config($mt5_app_config, $landing_company, $platform, $stage);

            # Test that the URLs are the expected URLs
            for my $link_type (keys %{$landing_companies{$landing_company}}) {
                my $expected_url = $landing_companies{$landing_company}{$link_type};
                $expected_url =~ s/\[platform\]/$platform/g;
                is($white_label_links->$link_type, $expected_url, "$link_type is correct for $landing_company platform $platform");
            }
        }
    }

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
        {
            'p03_ts01' => {
                'environment' => 'Deriv-Server-03',
                'geolocation' => {
                    'group'    => 'asia_synthetic',
                    'location' => 'Hong Kong',
                    'region'   => 'Asia',
                    'sequence' => 3
                }}
        },
    ];

    cmp_bag($all_servers, $expected_structure, 'Correct structure for servers');

    $mt5_obj = BOM::Config::MT5->new(group_type => 'demo');
    is scalar @{$mt5_obj->servers()}, 4, 'correct number of demo servers';

    $mt5_obj = BOM::Config::MT5->new(group => 'demo\p01_ts01\synthetic\svg_std_usd');
    is scalar @{$mt5_obj->servers()}, 4, 'correct number of demo servers with group';

    $mt5_obj = BOM::Config::MT5->new(group_type => 'real');
    is scalar @{$mt5_obj->servers()}, 7, 'correct number of real servers retrieved with group_type';

    $mt5_obj = BOM::Config::MT5->new(group => 'real\p01_ts01\synthetic\svg_std_usd');
    is scalar @{$mt5_obj->servers()}, 7, 'correct number of real servers retrieved with group';
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
    subtest 'mt5 swap_free demo servers' => sub {
        my $mt5      = BOM::Config::MT5->new();
        my $expected = {
            'demo' => {
                'all' => [{
                        'geolocation' => {
                            'group'    => 'all',
                            'location' => 'Frankfurt',
                            'region'   => 'Europe',
                            'sequence' => 1
                        },
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp',, 'all'],
                        'recommended'        => 1,
                        'id'                 => 'p01_ts03',
                        'disabled'           => 0,
                        'environment'        => 'Deriv-Demo',
                    },
                ],
                'financial' => [],
                'synthetic' => []}};
        my $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'demo',
                sub_account_type => 'swap_free'
            });

        is_deeply($result, $expected, 'output expected for swap_free account demo server on Indonesia');

        delete $expected->{demo}{all};
        delete $expected->{demo}{financial};
        $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'demo',
                market_type      => 'synthetic',
                sub_account_type => 'swap_free'
            });

        is_deeply($result, $expected, 'output expected for swap_free account demo synthetic server on Indonesia');
    };

    subtest 'mt5 standard demo servers' => sub {
        my $mt5      = BOM::Config::MT5->new();
        my $expected = {
            'demo' => {
                'all'       => [],
                'financial' => [{
                        'geolocation' => {
                            'sequence' => 1,
                            'region'   => 'Europe',
                            'location' => 'Ireland',
                            group      => 'all',
                        },
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
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
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
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
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
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
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
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
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
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
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
                        'recommended'        => 0,
                        'id'                 => 'p01_ts02',
                        'disabled'           => 0,
                        'environment'        => 'Deriv-Demo'
                    }]}};
        my $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'demo',
                sub_account_type => 'standard'
            });

        is_deeply($result, $expected, 'output expected for standard mt5 account demo server on Indonesia');

        delete $expected->{demo}{all};
        delete $expected->{demo}{financial};
        $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'demo',
                market_type      => 'synthetic',
                sub_account_type => 'standard'
            });

        is_deeply($result, $expected, 'output expected for demo synthetic server on Indonesia');
    };

    subtest 'mt5 swap_free real servers' => sub {
        my $mt5      = BOM::Config::MT5->new();
        my $expected = {
            'real' => {
                'all' => [{
                        'environment' => 'Deriv-Server',
                        'disabled'    => 0,
                        'geolocation' => {
                            'sequence' => 1,
                            'region'   => 'Europe',
                            'location' => 'Ireland',
                            'group'    => 'all',
                        },
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
                        'recommended'        => 1,
                        'id'                 => 'p01_ts01'
                    },
                    {
                        'disabled'    => 0,
                        'environment' => 'Deriv-Server-02',
                        'geolocation' => {
                            'group'    => 'africa_derivez',
                            'location' => 'South Africa',
                            'region'   => 'Africa',
                            'sequence' => 2
                        },
                        'id'                 => 'p02_ts01',
                        'recommended'        => 0,
                        'supported_accounts' => ['all']
                    },
                ],
                'financial' => [],
                'synthetic' => []}};

        my $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'real',
                sub_account_type => 'swap_free'
            });

        is_deeply($result, $expected, 'output expected for swap_free account real server on Indonesia');

        delete $expected->{real}{all};
        delete $expected->{real}{financial};
        $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'real',
                market_type      => 'synthetic',
                sub_account_type => 'swap_free'
            });
        is_deeply($result, $expected, 'output expected for swap_free account real synthetic server on Indonesia');

    };

    subtest 'mt5 standard real server' => sub {
        my $mt5      = BOM::Config::MT5->new();
        my $expected = {
            'real' => {
                'all'       => [],
                'financial' => [{
                        'environment' => 'Deriv-Server',
                        'disabled'    => 0,
                        'geolocation' => {
                            'sequence' => 1,
                            'region'   => 'Europe',
                            'location' => 'Ireland',
                            group      => 'all',
                        },
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
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
                        'recommended' => 0,
                        'id'          => 'p03_ts01',
                        'geolocation' => {
                            'sequence' => 3,
                            'region'   => 'Asia',
                            'location' => 'Hong Kong',
                            group      => 'asia_synthetic'
                        },
                        'supported_accounts' => ['gaming'],
                        'environment'        => 'Deriv-Server-03',
                        'disabled'           => 1
                    }]}};

        my $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'real',
                sub_account_type => 'standard'
            });

        is_deeply($result, $expected, 'output expected for real server on Indonesia');

        $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'real',
                market_type      => 'all',
                sub_account_type => 'standard'
            });

        is_deeply($result->{real}{all}, $expected->{real}{all}, 'output expected for demo derivez server on Indonesia');

        delete $expected->{real}{all};
        delete $expected->{real}{financial};
        $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'real',
                market_type      => 'synthetic',
                sub_account_type => 'standard'
            });
        is_deeply($result, $expected, 'output expected for real synthetic server on Indonesia');
    };

    subtest 'mt5 zero_spread demo servers' => sub {
        my $mt5                       = BOM::Config::MT5->new();
        my $expected_demo_zero_spread = {
            'demo' => {
                'all' => [{
                        'environment' => 'Deriv-Demo',
                        'disabled'    => 0,
                        'geolocation' => {
                            'sequence' => 1,
                            'region'   => 'Europe',
                            'location' => 'Ireland',
                            group      => 'all',
                        },
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
                        'recommended'        => 1,
                        'id'                 => 'p01_ts01'
                    },
                    {
                        'environment' => 'Deriv-Demo',
                        'disabled'    => 0,
                        'geolocation' => {
                            'sequence' => 1,
                            'region'   => 'Europe',
                            'location' => 'Frankfurt',
                            group      => 'all',
                        },
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
                        'recommended'        => 0,
                        'id'                 => 'p01_ts03'
                    },
                    {
                        'environment' => 'Deriv-Demo',
                        'disabled'    => 0,
                        'geolocation' => {
                            'sequence' => 1,
                            'region'   => 'Europe',
                            'location' => 'Frankfurt',
                            group      => 'derivez',
                        },
                        'supported_accounts' => ['all'],
                        'recommended'        => 0,
                        'id'                 => 'p01_ts04'
                    },
                    {
                        'environment' => 'Deriv-Demo',
                        'disabled'    => 0,
                        'geolocation' => {
                            'sequence' => 1,
                            'region'   => 'US East',
                            'location' => 'N. Virginia',
                            group      => 'all',
                        },
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
                        'recommended'        => 0,
                        'id'                 => 'p01_ts02'
                    }
                ],
                'financial' => [],
                'synthetic' => []}};
        my $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'demo',
                sub_account_type => 'zero_spread'
            });

        is_deeply($result, $expected_demo_zero_spread, 'zero spread demo account offer both financial and synthetic');
    };

    subtest 'mt5 zero_spread demo servers' => sub {
        my $mt5                       = BOM::Config::MT5->new();
        my $expected_real_zero_spread = {
            'real' => {
                'all' => [{
                        'environment' => 'Deriv-Server',
                        'disabled'    => 0,
                        'geolocation' => {
                            'sequence' => 1,
                            'region'   => 'Europe',
                            'location' => 'Ireland',
                            'group'    => 'all',
                        },
                        'supported_accounts' => ['gaming', 'financial', 'financial_stp', 'all'],
                        'recommended'        => 1,
                        'id'                 => 'p01_ts01'
                    },
                    {
                        'disabled'    => 0,
                        'environment' => 'Deriv-Server-02',
                        'geolocation' => {
                            'group'    => 'africa_derivez',
                            'location' => 'South Africa',
                            'region'   => 'Africa',
                            'sequence' => 2
                        },
                        'id'                 => 'p02_ts01',
                        'recommended'        => 0,
                        'supported_accounts' => ['all']
                    },
                ],
                'financial' => [],
                'synthetic' => []}};

        my $result = $mt5->server_by_country(
            'id',
            {
                group_type       => 'real',
                sub_account_type => 'zero_spread'
            });

        is_deeply($result, $expected_real_zero_spread, 'zero spread real account offer both financial and synthetic');
    };
};

subtest 'available_groups' => sub {
    my $mt5_config = BOM::Config::MT5->new;
    # we should test the:
    # - filtering logic
    # - total group per landing company
    my @test_cases = ({
            filter  => {server_type => 'real'},
            count   => 126,
            comment => 'real groups'
        },
        {
            filter  => {server_type => 'demo'},
            count   => 33,
            comment => 'demo groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'svg'
            },
            count   => 50,
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
            count   => 30,
            comment => 'real svg synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'svg'
            },
            count   => 11,
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
            count                    => 21,
            comment                  => 'real maltainvest groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'maltainvest',
                market_type => 'financial'
            },
            allow_multiple_subgroups => 1,
            count                    => 21,
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
            count   => 29,
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
            count   => 12,
            comment => 'real bvi synthetic groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'bvi'
            },
            count   => 9,
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
            count                    => 16,
            comment                  => 'real vanuatu groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'vanuatu',
                market_type => 'financial'
            },
            allow_multiple_subgroups => 1,
            count                    => 4,
            comment                  => 'real vanuatu financial groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'vanuatu',
                market_type => 'synthetic'
            },
            count   => 12,
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
            count   => 2,
            comment => 'demo svg all groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'svg',
                market_type => 'all'
            },
            count   => 7,
            comment => 'real svg all groups'
        },
        {
            filter => {
                server_type => 'demo',
                company     => 'bvi',
                market_type => 'all'
            },
            count   => 4,
            comment => 'demo bvi all groups'
        },
        {
            filter => {
                server_type => 'real',
                company     => 'bvi',
                market_type => 'all'
            },
            count   => 8,
            comment => 'real bvi derivez groups'
        },

    );

    foreach my $test (@test_cases) {
        is $mt5_config->available_groups($test->{filter}, $test->{allow_multiple_subgroups}), $test->{count}, $test->{comment};
    }
};

done_testing();
