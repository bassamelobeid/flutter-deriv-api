#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 6;
use Test::Exception;
use Test::NoWarnings;

use BOM::Product::RiskProfile;
use BOM::Platform::Runtime;

subtest 'init' => sub {
    throws_ok { BOM::Product::RiskProfile->new } qr/required/, 'throws if required args not provided';
    lives_ok {
        BOM::Product::RiskProfile->new(
            underlying        => BOM::Market::Underlying->new('frxUSDJPY'),
            contract_category => 'callput',
            start_type        => 'spot',
            expiry_type       => 'tick',
            currency          => 'USD',
            barrier_category  => 'euro_atm',
            )
    }
    'ok if required args provided';
};

my %args = (
    underlying        => BOM::Market::Underlying->new('frxUSDJPY'),
    contract_category => 'callput',
    start_type        => 'spot',
    expiry_type       => 'tick',
    currency          => 'USD',
    barrier_category  => 'euro_atm',
);
subtest 'get_risk_profile' => sub {
    note("no custom profile set, gets the default risk profile for underlying");
    my $rp = BOM::Product::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'medium_risk', 'medium risk as default for major pairs';
    my $limit = $rp->custom_profiles;
    is scalar(@$limit), 1, 'only one profile';
    is $limit->[0]->{name},         'major_pairs_turnover_limit', 'correct name';
    is $limit->[0]->{risk_profile}, 'medium_risk',                'risk_profile is medium';
    is $limit->[0]->{submarket},    'major_pairs',                'submarket specific';

    note("set custom_product_profiles to no_business for forex market");
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "forex", "risk_profile": "no_business", "name": "test custom"}}');
    $rp = BOM::Product::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'no_business', 'no business overrides default risk_profile';
    $limit = $rp->custom_profiles;
    is scalar(@$limit), 2, 'only one profile';
    is $limit->[1]->{name},         'major_pairs_turnover_limit', 'correct name';
    is $limit->[1]->{risk_profile}, 'medium_risk',                'risk_profile is medium';
    is $limit->[1]->{submarket},    'major_pairs',                'submarket specific';
    is $limit->[0]->{name},         'test custom',                'correct name';
    is $limit->[0]->{risk_profile}, 'no_business',                'risk_profile is no business';
    is $limit->[0]->{market},       'forex',                      'market specific';

    $args{underlying} = BOM::Market::Underlying->new('R_100');
    $rp = BOM::Product::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'low_risk', 'low risk is default for volatility index';
    $limit = $rp->custom_profiles;
    is scalar(@$limit), 1, 'only one profile';
    is $limit->[0]->{name},         'volidx_turnover_limit', 'correct name';
    is $limit->[0]->{risk_profile}, 'low_risk',              'risk_profile is low';
    is $limit->[0]->{market},       'volidx',                'market specific';
};

subtest 'custom client profile' => sub {
    note("set volatility index to no business for client XYZ");
    BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles(
        '{"XYZ": {"reason": "test XYZ", "custom_limits": {"xxx": {"market": "volidx", "risk_profile": "no_business", "name": "test custom"}}}}');
    my $rp = BOM::Product::RiskProfile->new(%args);
    my @cl_pr = $rp->get_client_profiles('ABC');
    ok !@cl_pr, 'no custom client limit';
    @cl_pr = $rp->get_client_profiles('XYZ');
    ok @cl_pr, 'custom client limit';
};

subtest 'turnover limit parameters' => sub {
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "tick", "risk_profile": "no_business", "name": "test custom"}}');
    my $rp = BOM::Product::RiskProfile->new(%args, expiry_type => 'tick');
    is $rp->contract_info->{expiry_type}, 'tick', 'tick expiry';
    my $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok $param->[0]->{tick_expiry}, 'tick_expiry set to 1';
    is scalar(@{$param->[0]->{symbols}}), 6, '6 symbols selected';
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "intraday", "risk_profile": "no_business", "name": "test custom"}}');
    $rp = BOM::Product::RiskProfile->new(%args, expiry_type => 'intraday');
    is $rp->contract_info->{expiry_type}, 'intraday', 'intraday expiry';
    $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok !$param->[0]->{daily}, 'daily set to 0';
    is scalar(@{$param->[0]->{symbols}}), 6, '6 symbols selected';
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles(
        '{"xxx": {"market": "volidx", "expiry_type": "daily", "risk_profile": "no_business", "name": "test custom"}}');
    $rp = BOM::Product::RiskProfile->new(%args, expiry_type => 'daily');
    is $rp->contract_info->{expiry_type}, 'daily', 'daily expiry';
    $param = $rp->get_turnover_limit_parameters;
    is $param->[0]->{name},  'test custom', 'correct name';
    is $param->[0]->{limit}, 0,             'turnover limit correctly set to zero';
    ok $param->[0]->{daily}, 'daily set to 1';
    is scalar(@{$param->[0]->{symbols}}), 6, '6 symbols selected';
};

subtest 'empty limit condition' => sub {
    note("set custom_product_profiles to no_business without any condition");
    BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles('{"xxx": {"risk_profile": "no_business", "name": "test custom"}}');
    my $rp = BOM::Product::RiskProfile->new(%args);
    is $rp->get_risk_profile, 'low_risk', 'ignore profile with no conditions';
};

#cleanup
BOM::Platform::Runtime->instance->app_config->quants->custom_product_profiles('{}');
BOM::Platform::Runtime->instance->app_config->quants->custom_client_profiles('{}');
