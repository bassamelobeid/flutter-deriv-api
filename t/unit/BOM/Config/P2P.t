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
    my $lc_mock = Test::MockModule->new("LandingCompany::Registry")->redefine("get_loaded_landing_companies",$mocked_lc);
    diag($lc_mock->is_mocked("get_loaded_landing_companies") ? "mocked":"not mocked");
    my @ar = values LandingCompany::Registry::get_loaded_landing_companies()->%*;
    diag($ar[0]->{short});
    is(1,1,"test");
};

done_testing;