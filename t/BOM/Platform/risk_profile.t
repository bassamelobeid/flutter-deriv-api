#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 9;
use Test::Exception;
use Test::Warnings;

use Quant::Framework::Underlying;

use BOM::Platform::RiskProfile;
use BOM::Platform::Runtime;
use BOM::Test::Helper::Client qw(create_client);

my $ul = Quant::Framework::Underlying->new('frxUSDJPY');

subtest 'init' => sub {
    throws_ok { BOM::Platform::RiskProfile->new } qr/required/, 'throws if required args not provided';
    lives_ok {
        BOM::Platform::RiskProfile->new(
            contract_category              => 'callput',
            start_type                     => 'spot',
            expiry_type                    => 'tick',
            currency                       => 'USD',
            barrier_category               => 'euro_atm',
            landing_company                => 'costarica',
            symbol                         => $ul->symbol,
            market_name                    => $ul->market->name,
            submarket_name                 => $ul->submarket->name,
            underlying_risk_profile        => $ul->risk_profile,
            underlying_risk_profile_setter => $ul->risk_profile_setter,
            )
    }
    'ok if required args provided';
};

my %args = (
    contract_category              => 'callput',
    start_type                     => 'spot',
    expiry_type                    => 'tick',
    currency                       => 'USD',
    barrier_category               => 'euro_atm',
    landing_company                => 'costarica',
    symbol                         => $ul->symbol,
    market_name                    => $ul->market->name,
    submarket_name                 => $ul->submarket->name,
    underlying_risk_profile        => $ul->risk_profile,
    underlying_risk_profile_setter => $ul->risk_profile_setter,
);

subtest 'get_risk_profile' => sub {
    note("no custom profile set, gets the default risk profile for underlying");
    my $rp = BOM::Platform::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'medium_risk', 'medium risk as default for major pairs';
    my $limit = $rp->custom_profiles;
    is scalar(@$limit), 1, 'only one profile';
    is $limit->[0]->{name},         'major_pairs_turnover_limit', 'correct name';
    is $limit->[0]->{risk_profile}, 'medium_risk',                'risk_profile is medium';
    is $limit->[0]->{submarket},    'major_pairs',                'submarket specific';

    note("set custom_product_profiles to no_business for forex market");
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "forex", "risk_profile": "no_business", "name": "test custom"}}');
    $rp = BOM::Platform::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'no_business', 'no business overrides default risk_profile';
    $limit = $rp->custom_profiles;
    is scalar(@$limit), 2, 'only one profile';
    is $limit->[1]->{name},         'major_pairs_turnover_limit', 'correct name';
    is $limit->[1]->{risk_profile}, 'medium_risk',                'risk_profile is medium';
    is $limit->[1]->{submarket},    'major_pairs',                'submarket specific';
    is $limit->[0]->{name},         'test custom',                'correct name';
    is $limit->[0]->{risk_profile}, 'no_business',                'risk_profile is no business';
    is $limit->[0]->{market},       'forex',                      'market specific';

    note("set custom_product_profiles to no_business for landing_company japan");
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"landing_company": "japan", "risk_profile": "no_business", "name": "test japan"}}');
    $rp = BOM::Platform::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'medium_risk', 'default medium_risk profile received because mismatch of landing_company';
    $limit = $rp->custom_profiles;
    is scalar(@$limit), 1, 'only one profile';
    $rp = BOM::Platform::RiskProfile->new(%args, landing_company => 'japan');
    my @cp = $rp->get_client_profiles('JP1110', 'japan');
    is $rp->get_risk_profile(\@cp), 'no_business', 'no_business overrides default medium_risk profile when landing_company matches';
    $limit = $rp->custom_profiles;
    is scalar(@$limit), 1, 'only one profile from custom';
    is scalar(@cp),     1, 'one from client';

    $ul   = Quant::Framework::Underlying->new('R_100');
    %args = (
        contract_category              => 'callput',
        start_type                     => 'spot',
        expiry_type                    => 'tick',
        currency                       => 'USD',
        barrier_category               => 'euro_atm',
        landing_company                => 'costarica',
        symbol                         => $ul->symbol,
        market_name                    => $ul->market->name,
        submarket_name                 => $ul->submarket->name,
        underlying_risk_profile        => $ul->risk_profile,
        underlying_risk_profile_setter => $ul->risk_profile_setter,
    );
    $rp = BOM::Platform::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'low_risk', 'low risk is default for volatility index';
    $limit = $rp->custom_profiles;
    is scalar(@$limit), 1, 'only one profile';
    is $limit->[0]->{name},         'volidx_turnover_limit', 'correct name';
    is $limit->[0]->{risk_profile}, 'low_risk',              'risk_profile is low';
    is $limit->[0]->{market},       'volidx',                'market specific';
};

subtest 'comma separated entries' => sub {
    note("set custom_product_profiles to no_business for frxUSDJPY & frxAUDJPY");
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "forex", "underlying_symbol": "frxUSDJPY,frxAUDJPY", "risk_profile": "no_business", "name": "test custom"}}');
    is $args{symbol}, 'R_100', 'symbol is R_100';
    my $rp = BOM::Platform::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'low_risk', 'risk profile for R_100 is low_risk';
    $args{market_name} = 'forex';
    $args{symbol}      = 'frxUSDJPY';
    $rp                = BOM::Platform::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'no_business', 'risk profile for frxUSDJPY is no_business';
    $args{symbol} = 'frxAUDJPY';
    $rp = BOM::Platform::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'no_business', 'risk profile for frxAUDJPY is no_business';
    $args{symbol} = 'frxAUDUSD';
    $rp = BOM::Platform::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'low_risk', 'risk profile for frxAUDUSD is low_risk';
    $args{market_name} = 'volidx';
    $args{symbol}      = 'R_100';
};

subtest 'custom client profile' => sub {
    note("set volatility index to no business for client XYZ");
    BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles(
        '{"CR1": {"reason": "test XYZ", "custom_limits": {"xxx": {"market": "volidx", "risk_profile": "no_business", "name": "test custom"}}}}');
    my $rp = BOM::Platform::RiskProfile->new(%args);
    my @cl_pr = $rp->get_client_profiles('CR2', 'costarica');
    ok !@cl_pr, 'no custom client limit';
    @cl_pr = $rp->get_client_profiles('CR1', 'costarica');
    ok @cl_pr, 'custom client limit';
};

subtest 'turnover limit parameters' => sub {
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "tick", "risk_profile": "no_business", "name": "test custom"}}');
    my $rp = BOM::Platform::RiskProfile->new(%args, expiry_type => 'tick');
    is $rp->contract_info->{expiry_type}, 'tick', 'tick expiry';
    my $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok $param->[0]->{tick_expiry}, 'tick_expiry set to 1';
    is scalar(@{$param->[0]->{symbols}}), 7, '7 symbols selected';
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "intraday", "risk_profile": "no_business", "name": "test custom"}}');
    $rp = BOM::Platform::RiskProfile->new(%args, expiry_type => 'intraday');
    is $rp->contract_info->{expiry_type}, 'intraday', 'intraday expiry';
    $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok !$param->[0]->{daily}, 'daily set to 0';
    is scalar(@{$param->[0]->{symbols}}), 7, '7 symbols selected';
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "daily", "risk_profile": "no_business", "name": "test custom"}}');
    $rp = BOM::Platform::RiskProfile->new(%args, expiry_type => 'daily');
    is $rp->contract_info->{expiry_type}, 'daily', 'daily expiry';
    $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok $param->[0]->{daily}, 'daily set to 1';
    is scalar(@{$param->[0]->{symbols}}), 7, '7 symbols selected';
};

subtest 'empty limit condition' => sub {
    note("set custom_product_profiles to no_business without any condition");
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles('{"xxx": {"risk_profile": "no_business", "name": "test custom"}}');
    my $rp = BOM::Platform::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'low_risk', 'ignore profile with no conditions';
};

subtest 'get_current_profile_definitions' => sub {
    my $expected = {
        'CR' => {
            'commodities' => [{
                    'turnover_limit' => "50000.00",
                    'payout_limit'   => "5000.00",
                    'name'           => 'Commodities',
                    'profile_name'   => 'high_risk'
                }
            ],
            'volidx' => [{
                    'turnover_limit' => "500000.00",
                    'payout_limit'   => "50000.00",
                    'name'           => 'Volatility Indices',
                    'profile_name'   => 'low_risk'
                }
            ],
            'forex' => [{
                    'turnover_limit' => "100000.00",
                    'payout_limit'   => "20000.00",
                    'name'           => 'Major Pairs',
                    'profile_name'   => 'medium_risk',
                },
                {
                    'turnover_limit' => "50000.00",
                    'payout_limit'   => "5000.00",
                    'name'           => 'Minor Pairs',
                    'profile_name'   => 'high_risk',
                },
                {
                    'turnover_limit' => "50000.00",
                    'payout_limit'   => "5000.00",
                    'name'           => 'Smart FX',
                    'profile_name'   => 'high_risk',
                },
            ],
            'stocks' => [{
                    'turnover_limit' => "1000.00",
                    'payout_limit'   => "100.00",
                    'name'           => 'OTC Stocks',
                    'profile_name'   => 'extreme_risk'
                }
            ],
            'indices' => [{
                    'turnover_limit' => "100000.00",
                    'payout_limit'   => "20000.00",
                    'name'           => 'Indices',
                    'profile_name'   => 'medium_risk'
                }
            ],
        },
        'JP' => {
            'forex' => [{
                    'turnover_limit' => "500000.00",
                    'payout_limit'   => "100000.00",
                    'name'           => 'Major Pairs',
                    'profile_name'   => 'medium_risk',
                }
            ],
        }};
    foreach my $broker (keys %$expected) {
        my $client  = create_client($broker);
        my $general = BOM::Platform::RiskProfile::get_current_profile_definitions($client);
        is_deeply($general, $expected->{$broker}, $broker);
    }
};

subtest 'check for risk_profile consistency' => sub {
    # We had a bug where we use 'each' to iterate over match conditions without resetting the iterator.
    # It is replaced with 'keys'
    # This test ensures we don't have this problem again.
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"yyy": {"market": "forex", "contract_category": "callput", "risk_profile": "high_risk", "name": "test2", "updated_on": "xxx date", "updated_by": "xxyy"}}'
    );
    my %expected = (
        callput      => 'high_risk',
        touchnotouch => 'medium_risk',
    );
    for (0 .. 4) {
        for my $bc ('touchnotouch', 'callput') {
            $ul = Quant::Framework::Underlying->new('frxUSDJPY');
            my $rp = BOM::Platform::RiskProfile->new(
                contract_category              => $bc,
                start_type                     => 'spot',
                expiry_type                    => 'tick',
                currency                       => 'USD',
                barrier_category               => 'euro_atm',
                landing_company                => 'costarica',
                symbol                         => $ul->symbol,
                market_name                    => $ul->market->name,
                submarket_name                 => $ul->submarket->name,
                underlying_risk_profile        => $ul->risk_profile,
                underlying_risk_profile_setter => $ul->risk_profile_setter,
            );
            is $rp->get_risk_profile, $expected{$bc}, 'same profile after iteration';
        }
    }
};

#cleanup
BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles('{}');
BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles('{}');
