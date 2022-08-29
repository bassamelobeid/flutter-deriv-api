use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::MockModule;

use BOM::Config::P2P;
use BOM::Config::Runtime;

my $config = BOM::Config::Runtime->instance->app_config->payments->p2p;

my $mock_countries = Test::MockModule->new('Brands::Countries');
my $country_data   = {
    aa => {
        name              => 'aa country',
        financial_company => 'lc1',
        gaming_company    => 'lc1'
    },
    bb => {
        name              => 'bb country',
        financial_company => 'none',
        gaming_company    => 'lc1'
    },
    cc => {
        name              => 'cc country',
        financial_company => 'lc1',
        gaming_company    => 'none'
    },
    dd => {
        name              => 'dd country',
        financial_company => 'lc2',
        gaming_company    => 'lc2'
    },
    ee => {
        name              => 'ee country',
        financial_company => 'none',
        gaming_company    => 'none'
    },
};
$mock_countries->redefine(countries_list => $country_data);

my $mock_lc = Test::MockModule->new('LandingCompany::Registry');
my $lc_data = {
    'LC 1' => {
        short         => 'lc1',
        p2p_available => 1
    },
    'LC 2' => {
        short         => 'lc2',
        p2p_available => 0
    },
};
$mock_lc->redefine(get_loaded_landing_companies => $lc_data);

subtest 'restricted_countries' => sub {

    $config->available(1);
    $config->restricted_countries([]);

    cmp_deeply(
        BOM::Config::P2P::available_countries,
        {
            aa => 'aa country',
            bb => 'bb country',
            cc => 'cc country'
        },
        'all countries'
    );

    $config->available(0);
    cmp_deeply(BOM::Config::P2P::available_countries, {}, 'no available countries');

    $config->available(1);
    $config->restricted_countries(['aa', 'bb']);

    cmp_deeply(
        BOM::Config::P2P::available_countries,
        {

            cc => 'cc country'
        },
        'some available countries'
    );

    $config->restricted_countries(['aa', 'bb', 'cc']);
    cmp_deeply(BOM::Config::P2P::available_countries, {}, 'all countries restricted');
};

subtest 'advert_config' => sub {
    $config->float_rate_global_max_range(99);
    $config->available(1);
    $config->restricted_countries(['bb', 'cc']);
    $config->country_advert_config('{}');

    cmp_deeply(
        BOM::Config::P2P::advert_config,
        {
            aa => {
                float_ads          => 'disabled',
                fixed_ads          => 'enabled',
                max_rate_range     => 99,
                manual_quote       => undef,
                manual_quote_epoch => undef,
                deactivate_fixed   => undef,
            }
        },
        'default country config'
    );

    $config->country_advert_config(
        '{ "aa": { "float_ads": "enabled", "max_rate_range": 88, "manual_quote": 1.23, "manual_quote_epoch" : 1234, "deactivate_fixed" : "2030-01-01" } }'
    );

    cmp_deeply(
        BOM::Config::P2P::advert_config,
        {
            aa => {
                float_ads          => 'enabled',
                fixed_ads          => 'enabled',
                max_rate_range     => 88,
                manual_quote       => 1.23,
                manual_quote_epoch => 1234,
                deactivate_fixed   => '2030-01-01',
            }
        },
        'override country config'
    );

};

done_testing();
