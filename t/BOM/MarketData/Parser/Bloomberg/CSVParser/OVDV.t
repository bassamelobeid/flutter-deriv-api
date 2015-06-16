use Test::Most qw(-Test::Deep);
use Test::MockObject::Extends;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );

use Date::Utility;
use BOM::MarketData::Parser::Bloomberg::VolSurfaces;

use File::Basename qw( dirname );
my $raw_data_dir = dirname(__FILE__) . '/../../../../../data/bbdl';

use_ok('BOM::MarketData::Parser::Bloomberg::CSVParser::OVDV');

subtest sanity_check => sub {
    plan tests => 2;

    my $parser;
    lives_ok { $parser = BOM::MarketData::Parser::Bloomberg::CSVParser::OVDV->new } 'can instantiate ovdv parser';
    can_ok($parser, 'extract_volsurface_params');
};

subtest errorcheck => sub {
    plan tests => 1;

    my $bb_error = $raw_data_dir . '/OVDV/errorcheck/bb_error.csv';
    my $parser   = BOM::MarketData::Parser::Bloomberg::CSVParser::OVDV->new;

    warning_like {
        $parser->extract_volsurface_params($bb_error);
    }
    qr/grabbed from Bloomberg has errors/, 'extract_volsurface_params throws warning.';

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

subtest 'parse data for ovdv' => sub {
    my $data = BOM::MarketData::Parser::Bloomberg::VolSurfaces->new->parse_data_for("$raw_data_dir/OVDV/2012-08-13/fx060000.csv", 'OVDV');
    is scalar keys %$data, 43, 'successfully parsed 43 underlyings';
};

subtest 'Flattening due to negative BF.' => sub {
    my $data = BOM::MarketData::Parser::Bloomberg::VolSurfaces->new->parse_data_for("$raw_data_dir/OVDV/2012-04-09/fx234559.csv", 'OVDV');
    my $eurjpy = $data->{frxEURJPY};
    is($eurjpy->recorded_date->datetime_yyyymmdd_hhmmss, '2012-04-09 23:45:59', '->get gets surface we are looking for.');

    is(
        $eurjpy->get_volatility({
                tenor => 'ON',
                delta => 25,
            }
        ),
        0.1522675,
        '25D has been flattened.',
    );
    is(
        $eurjpy->get_volatility({
                tenor => 'ON',
                delta => 50,
            }
        ),
        0.161,
        'ATM has been "flattened" (i.e. still the same).',
    );
    is(
        $eurjpy->get_volatility({
                tenor => 'ON',
                delta => 75,
            }
        ),
        0.1697325,
        '75D has been flattened.',
    );

    my $not_flattened_data = BOM::MarketData::Parser::Bloomberg::VolSurfaces->new(
        flatten_ON => 0,
    )->parse_data_for("$raw_data_dir/OVDV/2012-04-09/fx234559.csv", 'OVDV');
    my $eurjpy_raw = $not_flattened_data->{frxEURJPY};

    cmp_ok(
        $eurjpy->get_volatility({
                tenor => 'ON',
                delta => 25,
            }
        ),
        '!=',
        $eurjpy_raw->get_volatility({
                tenor => 'ON',
                delta => 25,
            }
        ),
        'Raw and flattened 25D vol are not equal.',
    );
    cmp_ok(
        $eurjpy->get_volatility({
                tenor => 'ON',
                delta => 50,
            }
        ),
        '==',
        $eurjpy_raw->get_volatility({
                tenor => 'ON',
                delta => 50,
            }
        ),
        'Raw and flattened ATM vol are equal.',
    );
    cmp_ok(
        $eurjpy->get_volatility({
                tenor => 'ON',
                delta => 75,
            }
        ),
        '!=',
        $eurjpy_raw->get_volatility({
                tenor => 'ON',
                delta => 75,
            }
        ),
        'Raw and flattened 75D vol are not equal.',
    );
};

done_testing;
