use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Test::MockModule;
use Test::MockObject;
use BOM::Config::P2P;
use Brands::Countries;

subtest 'available_countries' => sub {
    my $mocked_lc = {
        'Deriv (Europe) Limited' => {
            'short'         => 'malta',
            'p2p_available' => 1
        },
        'Deriv (SVG) LLC' => {
            'short'         => 'svg',
            'p2p_available' => 1
        }};
    my $mocked_countries_list = {
        'ad' => {
            'financial_company' => 'svg',
            'gaming_company'    => 'svg',
            'name'              => 'Andorra'
        },
        'ae' => {
            'financial_company' => 'malta',
            'gaming_company'    => 'malta',
            'name'              => 'Unit Arab Emirates'
        }};
    my $expected = {
        'ad' => 'Andorra',
        'ae' => 'Unit Arab Emirates'
    };
    my $mocked_p2p_availability     = 1;
    my $mocked_restricted_countries = ['in', 'us'];

    my $lc_mock      = Test::MockModule->new("LandingCompany::Registry")->redefine("get_loaded_landing_companies", sub { return $mocked_lc });
    my $country_mock = Test::MockModule->new("Brands::Countries")->redefine("countries_list", sub { return $mocked_countries_list });
    my $p2p_config   = BOM::Config::Runtime->instance->app_config->payments->p2p;
    my $mocked_p2p   = Test::MockModule->new(ref $p2p_config);
    $mocked_p2p->redefine("available",            sub { return $mocked_p2p_availability });
    $mocked_p2p->redefine("restricted_countries", sub { return $mocked_restricted_countries });

    is_deeply(BOM::Config::P2P::available_countries(), $expected, "countries that satisfy all conditions");

    $mocked_countries_list = {
        'ad' => {
            'financial_company' => 'svg',
            'gaming_company'    => 'svg',
            'name'              => 'Andorra'
        },
        'us' => {
            'financial_company' => 'svg',
            'gaming_company'    => 'svg',
            'name'              => 'Andorra'
        }};
    $mocked_restricted_countries = ['us'];
    $expected                    = {'ad' => 'Andorra'};
    is_deeply(BOM::Config::P2P::available_countries(), $expected, "restricted country is specefied");

    $mocked_countries_list = {
        'ad' => {
            'financial_company' => 'svg',
            'gaming_company'    => 'not a valid lc',
            'name'              => 'Andorra'
        },
        'ae' => {
            'financial_company' => 'not a valid lc',
            'gaming_company'    => 'not a valid lc',
            'name'              => 'Unit Arab Emirates'
        }};
    $expected = {'ad' => 'Andorra'};
    is_deeply(BOM::Config::P2P::available_countries(), $expected, "invalid landing company is specified");

    $mocked_countries_list = {};
    $expected              = {};
    is_deeply(BOM::Config::P2P::available_countries(), $expected, "empty countries list");

    $mocked_p2p_availability = 0;
    $expected                = {};
    is_deeply(BOM::Config::P2P::available_countries(), $expected, "p2p availability is false");

};

subtest 'advert_config' => sub {
    my $mocked_country_advert_config;
    my $expected;
    my $mocked_global_max_range;
    my $mocked_available_countries = {
        'ad' => 'Andorra',
        'ae' => 'United Arab Emirates'
    };

    my $p2p_config        = BOM::Config::Runtime->instance->app_config->payments->p2p;
    my $mocked_p2p_config = Test::MockModule->new(ref $p2p_config);
    $mocked_p2p_config->redefine("country_advert_config",       sub { return $mocked_country_advert_config });
    $mocked_p2p_config->redefine("float_rate_global_max_range", sub { return $mocked_global_max_range });
    my $mocked_p2p = Test::MockModule->new("BOM::Config::P2P");
    $mocked_p2p->redefine("available_countries", sub { return $mocked_available_countries });

    $mocked_country_advert_config =
        '{ "ad": {"float_ads": "enabled","fixed_ads": "enabled", "max_rate_range": 12, "manual_quote": 15, "manual_quote_epoch": 2, "deactivate_fixed": 1 },
    "ae": {"float_ads": "enabled","fixed_ads": "enabled", "max_rate_range": 8,"manual_quote": 25 ,"manual_quote_epoch" : 5, "deactivate_fixed": 2 } }';
    $expected = {
        'ad' => {
            "float_ads"          => 'enabled',
            "fixed_ads"          => 'enabled',
            "max_rate_range"     => 12,
            "manual_quote"       => 15,
            "manual_quote_epoch" => 2,
            "deactivate_fixed"   => 1
        },
        'ae' => {
            "float_ads"          => 'enabled',
            "fixed_ads"          => 'enabled',
            "max_rate_range"     => 8,
            "manual_quote"       => 25,
            "manual_quote_epoch" => 5,
            "deactivate_fixed"   => 2
        }};
    $mocked_global_max_range = 10;
    is_deeply(BOM::Config::P2P::advert_config(), $expected, "All config fields are updated correctly ");

    $mocked_country_advert_config = '{ "ad": {"fixed_ads": "enabled", "manual_quote": 15, "manual_quote_epoch": 2, "deactivate_fixed": 1 },
    "ae": {"float_ads": "enabled", "max_rate_range": 8,"manual_quote": 25 ,"manual_quote_epoch" : 2, "deactivate_fixed": 1 } }';
    $expected = {
        'ad' => {
            "float_ads"          => 'disabled',
            "fixed_ads"          => 'enabled',
            "max_rate_range"     => $mocked_global_max_range,
            "manual_quote"       => 15,
            "manual_quote_epoch" => 2,
            "deactivate_fixed"   => 1
        },
        'ae' => {
            "float_ads"          => 'enabled',
            "fixed_ads"          => 'enabled',
            "max_rate_range"     => 8,
            "manual_quote"       => 25,
            "manual_quote_epoch" => 2,
            "deactivate_fixed"   => 1
        }};
    $mocked_global_max_range = 10;
    is_deeply(BOM::Config::P2P::advert_config(), $expected, "float_ads, fixed_ads, max_rate_range fields are missing");

    $mocked_country_advert_config = '{ "ad": {"float_ads": "enabled","fixed_ads": "enabled", "max_rate_range": 12 },
    "ae": {"float_ads": "enabled","fixed_ads": "enabled", "max_rate_range": 8,"manual_quote": 25 ,"manual_quote_epoch" : 5, "deactivate_fixed": 2 } }';
    $expected = {
        'ad' => {
            "float_ads"          => 'enabled',
            "fixed_ads"          => 'enabled',
            "max_rate_range"     => 12,
            "manual_quote"       => undef,
            "manual_quote_epoch" => undef,
            "deactivate_fixed"   => undef
        },
        'ae' => {
            "float_ads"          => 'enabled',
            "fixed_ads"          => 'enabled',
            "max_rate_range"     => 8,
            "manual_quote"       => 25,
            "manual_quote_epoch" => 5,
            "deactivate_fixed"   => 2
        }};
    $mocked_global_max_range = 10;
    is_deeply(BOM::Config::P2P::advert_config(), $expected, "manual_quote, manual_quote_epoch, deactivate_fixed fields are missing");
};

done_testing;
