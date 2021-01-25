use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;

use BOM::Config::MT5;

subtest 'server details' => sub {
    my $mt5_obj = BOM::Config::MT5->new();
    like(exception { $mt5_obj->server_details() }, qr/Invalid server id. Please provide a valid server id./, 'die if server id is not provided');

    $mt5_obj = BOM::Config::MT5->new(server_id => 'real05');
    is $mt5_obj->server_details()->{type},   'real', 'type is correct';
    is $mt5_obj->server_details()->{number}, '05',   'number is correct';
};

subtest 'create server structure' => sub {
    my $mt5_obj = BOM::Config::MT5->new();

    my $structure = BOM::Config::MT5::create_server_structure(server => $mt5_obj->config()->{"real"}{"01"});
    is $structure, undef, 'undef if server key is not provided';

    $structure = BOM::Config::MT5::create_server_structure(server_type => 'real');
    is $structure, undef, 'undef if server is not provided';

    $structure = BOM::Config::MT5::create_server_structure(
        server_type => 'real',
        server      => $mt5_obj->config()->{"real"}{"01"});

    my $expected_structure = {
        'real01' => {
            'environment' => 'env_01',
            'geolocation' => {
                'location' => 'Ireland',
                'region'   => 'Europe',
                'sequence' => 1
            },
        },
    };

    cmp_deeply($structure, $expected_structure, 'got correct server result structure');
};

subtest 'server geolocation' => sub {
    my $mt5_obj = BOM::Config::MT5->new();
    like(exception { $mt5_obj->server_geolocation() }, qr/Invalid server id. Please provide a valid server id./, 'die if server id is not provided');

    $mt5_obj = BOM::Config::MT5->new(server_id => 'sample');
    like(
        exception { $mt5_obj->server_geolocation() },
        qr/Cannot extract server type and number from the server id provided/,
        'die if server id is not that we know'
    );

    $mt5_obj = BOM::Config::MT5->new(server_id => 'real05');
    like(exception { $mt5_obj->server_geolocation() }, qr/Provided server id does not exist in our config/, 'undef if server id is not that we know');

    $mt5_obj = BOM::Config::MT5->new(server_id => 'real01');
    is $mt5_obj->server_geolocation()->{region},   'Europe',  'correct server region';
    is $mt5_obj->server_geolocation()->{location}, 'Ireland', 'correct server location';
    is $mt5_obj->server_geolocation()->{sequence}, 1,         'correct server sequence';

    $mt5_obj = BOM::Config::MT5->new(server_id => 'real02');
    is $mt5_obj->server_geolocation()->{region},   'Africa',       'correct server region';
    is $mt5_obj->server_geolocation()->{location}, 'South Africa', 'correct server location';
    is $mt5_obj->server_geolocation()->{sequence}, 1,              'correct server sequence';
};

subtest 'server by id' => sub {
    my $mt5_obj = BOM::Config::MT5->new();
    like(exception { $mt5_obj->server_by_id() }, qr/Invalid server id. Please provide a valid server id./, 'undef if server id is not provided');

    $mt5_obj = BOM::Config::MT5->new(server_id => 'sample');
    like(
        exception { $mt5_obj->server_by_id() },
        qr/Cannot extract server type and number from the server id provided./,
        'undef if server id is not that we know of'
    );

    my $server_id = 'real01';
    $mt5_obj = BOM::Config::MT5->new(server_id => $server_id);

    my $server = $mt5_obj->server_by_id();
    ok exists $server->{$server_id}, 'server id exists';
    ok exists $server->{$server_id}{geolocation}, 'geolocation exists';

    is $server->{$server_id}{geolocation}{region},   'Europe',  'undef if server id is not that we know of';
    is $server->{$server_id}{geolocation}{location}, 'Ireland', 'undef if server id is not that we know of';
};

subtest 'servers' => sub {
    my $mt5_obj     = BOM::Config::MT5->new();
    my $all_servers = $mt5_obj->servers();

    my $expected_structure = [{
            'demo01' => {
                'environment' => 'env_01',
                'geolocation' => {
                    'location' => 'Ireland',
                    'region'   => 'Europe',
                    'sequence' => 1
                }}
        },
        {
            'real01' => {
                'environment' => 'env_01',
                'geolocation' => {
                    'location' => 'Ireland',
                    'region'   => 'Europe',
                    'sequence' => 1
                }}
        },
        {
            'real02' => {
                'environment' => 'env_01',
                'geolocation' => {
                    'location' => 'South Africa',
                    'region'   => 'Africa',
                    'sequence' => 1
                }}
        },
        {
            'real03' => {
                'environment' => 'env_01',
                'geolocation' => {
                    'location' => 'Singapore',
                    'region'   => 'Asia',
                    'sequence' => 1
                }}
        },
        {
            'real04' => {
                'environment' => 'env_01',
                'geolocation' => {
                    'location' => 'Frankfurt',
                    'region'   => 'Europe',
                    'sequence' => 2
                },
            },
        },
    ];

    cmp_bag($all_servers, $expected_structure, 'Correct structure for servers');

    $mt5_obj = BOM::Config::MT5->new(type => 'demo');
    is scalar @{$mt5_obj->servers()}, 1, 'correct number of demo servers';

    $mt5_obj = BOM::Config::MT5->new(type => 'real');
    is scalar @{$mt5_obj->servers()}, 4, 'correct number of demo servers';
};

done_testing();
