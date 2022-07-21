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
            'short' => 'malta',
            'p2p_available' => 1
        },
        'Deriv (SVG) LLC' => {
            'short' => 'svg',
            'p2p_available' => 1
        }
    };
    my $mocked_countries_list = {
        'ad' => {
            'financial_company' => 'svg',
            'gaming_company' => 'svg',
            'name' => 'Andorra'
        },
        'ae' => {
            'financial_company' => 'malta',
            'gaming_company' => 'malta',
            'name' => 'Unit Arab Emirates'
        }
    };
    my $expected = {
        'ad' => 'Andorra',
        'ae' => 'Unit Arab Emirates'
    };
    my $mocked_p2p_availability = 1;
    my $mocked_restricted_countries = ['in','us'];

    my $lc_mock = Test::MockModule->new("LandingCompany::Registry")->redefine("get_loaded_landing_companies", sub { return $mocked_lc });
    my $country_mock = Test::MockModule->new("Brands::Countries")->redefine("countries_list", sub{ return $mocked_countries_list });
    my $p2p_config = BOM::Config::Runtime->instance->app_config->payments->p2p;
    my $mocked_p2p = Test::MockModule->new(ref $p2p_config);
    $mocked_p2p->redefine("available",sub{return $mocked_p2p_availability });
    $mocked_p2p->redefine("restricted_countries", sub {return $mocked_restricted_countries});

    is_deeply(BOM::Config::P2P::available_countries(),$expected,"countries that satisfy all conditions");

    $mocked_countries_list = { 
        'ad' => {
            'financial_company' => 'svg',
            'gaming_company' => 'svg',
            'name' => 'Andorra'
        },
        'us' => {
            'financial_company' => 'svg',
            'gaming_company' => 'svg',
            'name' => 'Andorra'
        }
    };
    $mocked_restricted_countries = ['us'];
    $expected = {
        'ad' => 'Andorra'
    };
    is_deeply(BOM::Config::P2P::available_countries(),$expected,"restricted country is specefied");

    $mocked_countries_list = {
        'ad' => {
            'financial_company' => 'svg',
            'gaming_company' => 'not a valid lc',
            'name' => 'Andorra'
        },
        'ae' => {
            'financial_company' => 'not a valid lc',
            'gaming_company' => 'not a valid lc',
            'name' => 'Unit Arab Emirates'
        }
    };
    $expected = {
        'ad' => 'Andorra'
    };
    is_deeply(BOM::Config::P2P::available_countries(),$expected,"invalid landing company is specified");

    $mocked_countries_list = {};
    $expected = {};
    is_deeply(BOM::Config::P2P::available_countries(),$expected, "empty countries list");

    $mocked_p2p_availability = 0;
    $expected = {};
    is_deeply(BOM::Config::P2P::available_countries(),$expected,"p2p availability is false");

};

done_testing;
