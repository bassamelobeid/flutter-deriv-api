#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Warnings;
use Test::Deep;

use Quant::Framework::Underlying;

use BOM::Platform::RiskProfile;
use BOM::Config::Runtime;
use BOM::Test::Helper::Client qw(create_client);

my $ul = Quant::Framework::Underlying->new('frxUSDJPY');

my $landing_company = 'svg';

subtest 'init' => sub {
    throws_ok { BOM::Platform::RiskProfile->new } qr/required/, 'throws if required args not provided';
    lives_ok {
        BOM::Platform::RiskProfile->new(
            contract_category              => 'callput',
            start_type                     => 'spot',
            expiry_type                    => 'tick',
            currency                       => 'USD',
            barrier_category               => 'euro_atm',
            landing_company                => $landing_company,
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
    landing_company                => $landing_company,
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
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
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

    $ul   = Quant::Framework::Underlying->new('R_100');
    %args = (
        contract_category              => 'callput',
        start_type                     => 'spot',
        expiry_type                    => 'tick',
        currency                       => 'USD',
        barrier_category               => 'euro_atm',
        landing_company                => $landing_company,
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
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
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
    BOM::Config::Runtime->instance->app_config->quants->custom_client_profiles(
        '{"CR1": {"reason": "test XYZ", "custom_limits": {"xxx": {"market": "volidx", "risk_profile": "no_business", "name": "test custom"}}}}');
    my $rp = BOM::Platform::RiskProfile->new(%args);
    my @cl_pr = $rp->get_client_profiles('CR2', $landing_company);
    ok !@cl_pr, 'no custom client limit';
    @cl_pr = $rp->get_client_profiles('CR1', $landing_company);
    ok @cl_pr, 'custom client limit';
};

subtest 'turnover limit parameters' => sub {
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "tick", "risk_profile": "no_business", "name": "test custom"}}');
    my $rp = BOM::Platform::RiskProfile->new(%args, expiry_type => 'tick');
    is $rp->contract_info->{expiry_type}, 'tick', 'tick expiry';
    my $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok $param->[0]->{tick_expiry}, 'tick_expiry set to 1';
    is scalar(@{$param->[0]->{symbols}}), 7, '7 symbols selected';
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "intraday", "risk_profile": "no_business", "name": "test custom"}}');
    $rp = BOM::Platform::RiskProfile->new(%args, expiry_type => 'intraday');
    is $rp->contract_info->{expiry_type}, 'intraday', 'intraday expiry';
    $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok !$param->[0]->{daily},       'daily set to 0';
    ok !$param->[0]->{ultra_short}, 'daily set to 0';
    is scalar(@{$param->[0]->{symbols}}), 7, '7 symbols selected';
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "daily", "risk_profile": "no_business", "name": "test custom"}}');
    $rp = BOM::Platform::RiskProfile->new(%args, expiry_type => 'daily');
    is $rp->contract_info->{expiry_type}, 'daily', 'daily expiry';
    $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok $param->[0]->{daily}, 'daily set to 1';
    is scalar(@{$param->[0]->{symbols}}), 7, '7 symbols selected';
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"underlying_symbol": "R_100,R_10", "expiry_type": "daily", "risk_profile": "no_business", "name": "test custom"}}');
    $rp = BOM::Platform::RiskProfile->new(%args, expiry_type => 'daily');
    is $rp->contract_info->{expiry_type}, 'daily', 'daily expiry';
    $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok $param->[0]->{daily}, 'daily set to 1';
    is scalar(@{$param->[0]->{symbols}}), 2, '2 symbols selected';
    is $param->[0]->{symbols}->[0], 'R_100', 'first symbol is R_100';
    is $param->[0]->{symbols}->[1], 'R_10',  'first symbol is R_10';

    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "ultra_short", "risk_profile": "no_business", "name": "test custom ultra_short"}}');
    $rp = BOM::Platform::RiskProfile->new(%args, expiry_type => 'ultra_short');
    is $rp->contract_info->{expiry_type}, 'ultra_short', 'ultra_short  expiry';
    $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name}, 'test custom ultra_short', 'correct name';
    is $param->[0]->{limit}, 0, 'turnover limit correctly set to zero';
    ok !$param->[0]->{daily}, 'daily set to 0';
    ok $param->[0]->{ultra_short}, 'daily set to 1';
    is scalar(@{$param->[0]->{symbols}}), 7, '7 symbols selected';
};

subtest 'empty limit condition' => sub {
    note("set custom_product_profiles to no_business without any condition");
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles('{"xxx": {"risk_profile": "no_business", "name": "test custom"}}');
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
            'indices' => [{
                    'turnover_limit' => "100000.00",
                    'payout_limit'   => "20000.00",
                    'name'           => 'Indices',
                    'profile_name'   => 'medium_risk'
                }
            ],
        },
    };
    foreach my $broker (keys %$expected) {
        my $client  = create_client($broker);
        my $general = BOM::Platform::RiskProfile::get_current_profile_definitions($client);
        foreach my $profile (keys %$general) {
            cmp_deeply($general->{$profile}, bag(@{$expected->{$broker}->{$profile}}), "$broker $profile");
        }
    }
};

subtest 'check for risk_profile consistency' => sub {
    # We had a bug where we use 'each' to iterate over match conditions without resetting the iterator.
    # It is replaced with 'keys'
    # This test ensures we don't have this problem again.
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
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
                landing_company                => $landing_company,
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

subtest 'commission profile' => sub {
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"yyy": {"market": "forex", "contract_category": "callput", "commission": "0.1", "barrier_category": "euro_non_atm", "name": "test2", "updated_on": "xxx date", "updated_by": "xxyy"}}'
    );
    $ul = Quant::Framework::Underlying->new('frxUSDJPY');
    my %args = (
        contract_category              => 'callput',
        start_type                     => 'spot',
        expiry_type                    => 'tick',
        currency                       => 'USD',
        barrier_category               => 'euro_atm',
        landing_company                => $landing_company,
        symbol                         => $ul->symbol,
        market_name                    => $ul->market->name,
        submarket_name                 => $ul->submarket->name,
        underlying_risk_profile        => $ul->risk_profile,
        underlying_risk_profile_setter => $ul->risk_profile_setter,
    );
    my $rp = BOM::Platform::RiskProfile->new(%args);

    ok !$rp->get_commission, 'no commission for euro_atm';
    $args{barrier_category} = 'euro_non_atm';
    $rp = BOM::Platform::RiskProfile->new(%args);
    ok $rp->get_commission, 'has custom commission for euro_non_atm';
    is $rp->get_commission, 0.1, 'commission is 0.1';

    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"yyy": {"market": "forex", "contract_category": "callput", "commission": "0.1", "barrier_category": "euro_non_atm", "name": "test2", "updated_on": "xxx date", "updated_by": "xxyy"}, "zyy": {"contract_category": "callput", "commission": "0.2", "name": "test2", "updated_on": "xxx date", "updated_by": "xxyy"}}'
    );
    $rp = BOM::Platform::RiskProfile->new(%args);
    ok $rp->get_commission, 'has custom commission for euro_non_atm';
    is $rp->get_commission, 0.2, 'got the higher commission, 0.2';
};

subtest 'precedence' => sub {
    BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"yyy": {"underlying_symbol": "frxUSDJPY", "market": "forex", "contract_category": "callput", "risk_profile": "high_risk", "name": "test2", "updated_on": "xxx date", "updated_by": "xxyy"}}'
    );
    $ul = Quant::Framework::Underlying->new('frxUSDJPY');
    my $rp = BOM::Platform::RiskProfile->new(
        contract_category              => 'callput',
        start_type                     => 'spot',
        expiry_type                    => 'tick',
        currency                       => 'USD',
        barrier_category               => 'euro_atm',
        landing_company                => $landing_company,
        symbol                         => $ul->symbol,
        market_name                    => $ul->market->name,
        submarket_name                 => $ul->submarket->name,
        underlying_risk_profile        => $ul->risk_profile,
        underlying_risk_profile_setter => $ul->risk_profile_setter,
    );
    my $params         = $rp->get_turnover_limit_parameters;
    my $custom_profile = $params->[0];
    is $custom_profile->{limit}, 50000, '50,000 turnover limit';
    is scalar(@{$custom_profile->{symbols}}), 1, 'only only symbol';
    is $custom_profile->{symbols}->[0], 'frxUSDJPY', 'symbol is frxUSDJPY even if market=forex is specified';
};

done_testing();
#cleanup
BOM::Config::Runtime->instance->app_config->quants->custom_product_profiles('{}');
BOM::Config::Runtime->instance->app_config->quants->custom_client_profiles('{}');
