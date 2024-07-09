use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new();

subtest 'rule residence.account_type_is_available' => sub {
    my $rule_name      = 'residence.account_type_is_available';
    my $companies      = {};
    my $mock_countries = Test::MockModule->new('Business::Config::Country');
    $mock_countries->redefine(
        derived_company   => sub { return $companies->{derived} },
        financial_company => sub { return $companies->{financial} });

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either residence or loginid is required/, 'loginid is required';
    my $args = {residence => 'es'};
    like exception { $rule_engine->apply_rules($rule_name, %$args) }, qr/Either landing_company or loginid is required/, 'loginid is required';
    $args = {
        residence       => 'es',
        landing_company => 'svg'
    };

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code  => 'InvalidAccount',
        rule        => $rule_name,
        description => 'Market type or landing company is invalid'
        },
        'correct error when market_type in not specified in args';

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code  => 'InvalidAccount',
        rule        => $rule_name,
        description => 'Market type or landing company is invalid'
        },
        'correct error when there is no matching landing_company';
    $companies->{derived} = 'abcd';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code  => 'InvalidAccount',
        rule        => $rule_name,
        description => 'Market type or landing company is invalid'
        },
        'Fails if the landing company matching market type is different form context landing company';

    $companies->{derived} = 'svg';
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Succeeds after setting the same landing company';

    $companies->{financial} = 'maltainvest';
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Succeeds after setting the same landing company';

    subtest 'affiliate type' => sub {
        $mock_countries->redefine(
            derived_company   => sub { return undef },
            financial_company => sub { return undef });

        $args->{account_type} = 'affiliate';
        $args->{category}     = 'wallet';
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
            {
            error_code  => 'InvalidAccount',
            rule        => $rule_name,
            description => 'Market type or landing company is invalid'
            },
            'correct error when there is no landing_company';

        $mock_countries->redefine(
            derived_company   => sub { return $companies->{derived} },
            financial_company => sub { return $companies->{financial} },
            wallet_companies  => sub { return ['dsl'] });

        $args->{landing_company} = 'dsl';
        lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Succeeds after setting valid lc companies';

    };

    $mock_countries->unmock_all;
};

subtest 'rule residence.not_restricted' => sub {
    my $rule_name = 'residence.not_restricted';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either residence or loginid is required/, 'loginid is required';
    my $args = {residence => 'es'};

    my $is_restricted  = 1;
    my $mock_countries = Test::MockModule->new('Business::Config::Country');
    $mock_countries->redefine(restricted => sub { return $is_restricted });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code  => 'InvalidResidence',
        rule        => $rule_name,
        description => 'Residence country is restricted'
        },
        'correct error when the country is restricted';
    $is_restricted = 0;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'rule apples if the country is not restricted';

    $mock_countries->unmock_all;
};

subtest 'residence.account_type_is_available_for_real_account_opening' => sub {
    my $rule_name = 'residence.account_type_is_available_for_real_account_opening';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either residence or loginid is required/, 'loginid is required';
    my $args = {
        residence       => 'es',
        landing_company => 'svg'
    };

    my $is_restricted = my $mock_countries = Test::MockModule->new('Business::Config::Country');
    my $wallet_lc;
    $mock_countries->redefine(
        wallet_companies => sub {
            my ($self, $country, $type) = @_;
            return [$wallet_lc] if $wallet_lc;
            return [];
        });

    like exception { $rule_engine->apply_rules($rule_name, %$args) }, qr/Account type is required/, 'Account type is missing';

    $args->{account_type} = 'binary';
    $args->{category}     = 'trading';
    is exception { $rule_engine->apply_rules($rule_name, %$args) }, undef, 'No error for trading account type';

    $args->{account_type} = 'affiliate';
    $args->{category}     = 'wallet';
    is exception { $rule_engine->apply_rules($rule_name, %$args) }, undef, 'No error for affiliate account type';

    $args->{account_type} = 'doughflow';
    $args->{category}     = 'wallet';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code  => 'InvalidResidence',
        rule        => $rule_name,
        description => 'Account type is not available for country of residence'
        },
        'correct error when the account type is disabled';

    $wallet_lc = 'svg';
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'rule apples if wallet landing company is not empty';

    $mock_countries->unmock_all;
};

subtest 'rule residence.is_country_enabled' => sub {
    my $rule_name = 'residence.is_country_enabled';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either residence or loginid is required/, 'loginid is required';
    my $args = {residence => 'es'};

    my $is_enabled     = 0;
    my $mock_countries = Test::MockModule->new('Business::Config::Country');
    $mock_countries->redefine(
        signup => sub {
            return {
                country_enabled => $is_enabled,
            };
        });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code  => 'InvalidAccount',
        rule        => $rule_name,
        description => 'Signup is not allowed for country of residence'
        },
        'correct error when country is disabled';
    $is_enabled = 1;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'rule passes if country is enabled';

    $mock_countries->unmock_all;
};

done_testing;
