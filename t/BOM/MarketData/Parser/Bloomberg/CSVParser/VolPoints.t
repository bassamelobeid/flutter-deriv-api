use Test::Most qw(-Test::Deep);
use Test::MockObject::Extends;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

use Date::Utility;
use Bloomberg::VolSurfaces;
use Format::Util::Numbers qw( roundnear );
use File::Basename qw( dirname );
my $raw_data_dir = dirname(__FILE__) . '/../../../../../data/bbdl';

use_ok('Bloomberg::CSVParser::VolPoints');

subtest sanity_check => sub {
    plan tests => 2;

    my $parser;
    lives_ok { $parser = Bloomberg::CSVParser::VolPoints->new() } 'can instantiate volpoint csv parser';
    can_ok($parser, 'extract_volsurface_params');
};

subtest error_check => sub {
    plan tests => 5;

    my $parser = Bloomberg::CSVParser::VolPoints->new();

    my $bb_error = $raw_data_dir . '/vol_points/errorcheck/bb_error.csv';
    warning_like { $parser->extract_volsurface_params($bb_error) } qr/Bloomberg has errors/, 'Warns if volsurface data has error';

    foreach my $type (qw( last ask bid )) {
        my $filename_with_error = "$raw_data_dir/vol_points/errorcheck/not_number_$type.csv";
        warning_like { $parser->extract_volsurface_params($filename_with_error) } qr/is not a number/, "Warns if $type-data is not a number in file.";
    }

    my $fake_sec = $raw_data_dir . '/vol_points/errorcheck/fake_sec.csv';
    warning_like { $parser->extract_volsurface_params($fake_sec) } qr/not recognized/, 'Warns if ticker data unrecognized';
};

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol => 'FOREX',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw(USD JPY SEK CHF GBP CAD NOK AUD EUR CZK PLN NZD);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new,
    });

subtest 'parse data for volpoints that contains full surface' => sub {
    my $data = Bloomberg::VolSurfaces->new->parse_data_for("$raw_data_dir/vol_points/2012-08-13/fx000000.csv", 'vol_points');
    ok $data->{frxAUDJPY}, 'parsed data for frxAUDJPY';
    ok $data->{frxUSDJPY}, 'parsed data for frxUSDJPY';
    my $audjpy = $data->{frxAUDJPY};
    my $usdjpy = $data->{frxUSDJPY};
    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => 'ON',
                    delta => 25,
                })
        ),
        0.1141,
        'AUDJPY ON 25D vol is correct.',
    );
    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => 'ON',
                    delta => 50,
                })
        ),
        0.1139,
        'AUDJPY ON ATM vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => 'ON',
                    delta => 75,
                })
        ),
        0.1234,
        'AUDJPYY ON 75D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1W',
                    delta => 75,
                })
        ),
        0.1097,
        'AUDJPY 1w 75D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1W',
                    delta => 25,
                })
        ),
        0.0956,
        'AUDJPY 1W 25D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1W',
                    delta => 50,
                })
        ),
        0.0979,
        'AUDJPY 1W ATM vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $usdjpy->get_volatility({
                    tenor => 'ON',
                    delta => 25,
                })
        ),
        0.0838,
        'USDJPY ON 25D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $usdjpy->get_volatility({
                    tenor => 'ON',
                    delta => 75,
                })
        ),
        0.0803,
        'USDJPY ON 75D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $usdjpy->get_volatility({
                    tenor => 'ON',
                    delta => 50,
                })
        ),
        0.0780,
        'USDJPY ON ATM vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $usdjpy->get_volatility({
                    tenor => '1W',
                    delta => 25,
                })
        ),
        0.0966,
        'USDJPY 1W 25D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $usdjpy->get_volatility({
                    tenor => '1W',
                    delta => 75,
                })
        ),
        0.0927,
        'USDJPY 1W 75D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $usdjpy->get_volatility({
                    tenor => '1W',
                    delta => 50,
                })
        ),
        0.0923,
        'USDJPY 1W ATM vol is correct.',
    );

    is(roundnear(0.0001, $audjpy->get_smile_spread(1)->{vol_spread}->{50}), 0.0893, 'AUDJPY ON ATM vol spread is correct.',);

    is(roundnear(0.0001, $audjpy->get_smile_spread(1)->{vol_spread}->{25}), 0.1276, 'AUDJPY ON 25D vol spread is correct.',);

    is(roundnear(0.0001, $audjpy->get_smile_spread(1)->{vol_spread}->{75}), 0.1276, 'AUDJPY ON 75D vol spread is correct.',);

    is(roundnear(0.0001, $usdjpy->get_smile_spread(1)->{vol_spread}->{50}), 0.0350, 'USDJPY ON ATM vol spread is correct.',);

    is(roundnear(0.0001, $usdjpy->get_smile_spread(1)->{vol_spread}->{25}), 0.0500, 'USDJPY ON 25D vol spread is correct.',);

    is(roundnear(0.0001, $usdjpy->get_smile_spread(1)->{vol_spread}->{75}), 0.0500, 'AUDJPY ON 75D vol spread is correct.',);

    my $AUDJPY_surface = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxAUDJPY',
            surface       => $audjpy->surface,
            recorded_date => $audjpy->recorded_date,
        });

};

subtest 'parse data for volpoints that contains half surface' => sub {
    my $data = Bloomberg::VolSurfaces->new->parse_data_for("$raw_data_dir/vol_points/2012-08-13/fx010000.csv", 'vol_points');
    ok $data->{frxAUDJPY}, 'parsed data for frxAUDJPY';
    my $audjpy = $data->{frxAUDJPY};
    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => 'ON',
                    delta => 25,
                })
        ),
        0.0932,
        'AUDJPY ON 25D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => 'ON',
                    delta => 50,
                })
        ),
        0.0954,
        'AUDJPY ON ATM vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => 'ON',
                    delta => 75,
                })
        ),
        0.1025,
        'AUDJPYY ON 75D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1W',
                    delta => 75,
                })
        ),
        0.1234,
        'AUDJPY 1W 75D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1W',
                    delta => 25,
                })
        ),
        0.1129,
        'AUDJPY 1W 25D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1W',
                    delta => 50,
                })
        ),
        0.1148,
        'AUDJPY 1W ATM vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1M',
                    delta => 25,
                })
        ),
        0.1065,
        'AUDJPY 1M 25D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1M',
                    delta => 75,
                })
        ),
        0.1247,
        'AUDJPY 1M 75D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1M',
                    delta => 50,
                })
        ),
        0.1115,
        'AUDJPY 1M ATM vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1Y',
                    delta => 25,
                })
        ),
        0.1285,
        'AUDJPY 1Y 25D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1Y',
                    delta => 75,
                })
        ),
        0.1863,
        'AUDJPY 1Y 75D vol is correct.',
    );

    is(
        roundnear(
            0.0001,
            $audjpy->get_volatility({
                    tenor => '1Y',
                    delta => 50,
                })
        ),
        0.1514,
        'AUDJPY 1Y ATM vol is correct.',
    );

    is(roundnear(0.0001, $audjpy->get_smile_spread(1)->{vol_spread}->{50}), 0.0480, 'AUDJPY ON ATM vol spread is correct.',);

    is(roundnear(0.0001, $audjpy->get_smile_spread(1)->{vol_spread}->{25}), 0.0686, 'AUDJPY ON 25D vol spread is correct.',);

    is(roundnear(0.0001, $audjpy->get_smile_spread(1)->{vol_spread}->{75}), 0.0686, 'AUDJPY ON 75D vol spread is correct.',);

    is(roundnear(0.0001, $audjpy->get_smile_spread(7)->{vol_spread}->{50}), 0.0175, 'AUDJPY 1W ATM vol spread is correct.',);

    is(roundnear(0.0001, $audjpy->get_smile_spread(7)->{vol_spread}->{25}), 0.0250, 'AUDJPY 1W 25D vol spread is correct.',);

    is(roundnear(0.0001, $audjpy->get_smile_spread(7)->{vol_spread}->{75}),  0.0250, 'AUDJPY 1W 75D vol spread is correct.',);
    is(roundnear(0.0001, $audjpy->get_smile_spread(31)->{vol_spread}->{50}), 0.0105, 'AUDJPY 1M ATM vol spread is correct.',);

    is(roundnear(0.0001, $audjpy->get_smile_spread(31)->{vol_spread}->{25}), 0.0150, 'AUDJPY 1M 25D vol spread is correct.',);

    is(roundnear(0.0001, $audjpy->get_smile_spread(31)->{vol_spread}->{75}), 0.0150, 'AUDJPY 1M 75D vol spread is correct.',);

};

done_testing;
