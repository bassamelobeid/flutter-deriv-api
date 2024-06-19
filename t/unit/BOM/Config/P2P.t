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

    my $instance              = BOM::Config::Runtime->instance;
    my $mocked_instance       = Test::MockObject->new($instance);
    my $mocked_app_config     = Test::MockObject->new();
    my $mocked_payment_config = Test::MockObject->new();
    my $mocked_p2p_config     = Test::MockObject->new();

    $mocked_instance->mock("app_config" => sub { return $mocked_app_config });
    $mocked_app_config->mock("payments" => sub { return $mocked_payment_config });
    $mocked_payment_config->mock("p2p" => sub { return $mocked_p2p_config });
    $mocked_p2p_config->mock("available"            => sub { return $mocked_p2p_availability });
    $mocked_p2p_config->mock("restricted_countries" => sub { return $mocked_restricted_countries });

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

    my $instance              = BOM::Config::Runtime->instance;
    my $mocked_instance       = Test::MockObject->new($instance);
    my $mocked_app_config     = Test::MockObject->new();
    my $mocked_payment_config = Test::MockObject->new();
    my $mocked_p2p_config     = Test::MockObject->new();

    $mocked_instance->mock("app_config" => sub { return $mocked_app_config });
    $mocked_app_config->mock("payments" => sub { return $mocked_payment_config });
    $mocked_payment_config->mock("p2p" => sub { return $mocked_p2p_config });
    $mocked_p2p_config->mock("country_advert_config"       => sub { return $mocked_country_advert_config });
    $mocked_p2p_config->mock("float_rate_global_max_range" => sub { return $mocked_global_max_range });

    my $mocked_p2p = Test::MockModule->new("BOM::Config::P2P");
    $mocked_p2p->redefine("available_countries", sub { return $mocked_available_countries });

    $mocked_country_advert_config = '{ "ad": {"float_ads": "enabled","fixed_ads": "enabled", "deactivate_fixed": 1 },
           "ae": {"float_ads": "enabled","fixed_ads": "enabled", "deactivate_fixed": 2 } }';
    $expected = {
        'ad' => {
            "float_ads"        => 'enabled',
            "fixed_ads"        => 'enabled',
            "deactivate_fixed" => 1
        },
        'ae' => {
            "float_ads"        => 'enabled',
            "fixed_ads"        => 'enabled',
            "deactivate_fixed" => 2
        }};

    is_deeply(BOM::Config::P2P::advert_config(), $expected, "All config fields are updated correctly ");
};

done_testing;
