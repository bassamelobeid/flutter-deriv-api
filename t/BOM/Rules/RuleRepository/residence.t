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
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(
        gaming_company_for_country    => sub { return $companies->{synthetic} },
        financial_company_for_country => sub { return $companies->{financial} });

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either residence or loginid is required/, 'loginid is required';
    my $args = {residence => 'es'};
    like exception { $rule_engine->apply_rules($rule_name, %$args) }, qr/Either landing_company or loginid is required/, 'loginid is required';
    $args = {
        residence       => 'es',
        landing_company => 'svg'
    };

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'InvalidAccount',
        rule       => $rule_name
        },
        'correct error when market_type in not specified in args';

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'InvalidAccount',
        rule       => $rule_name
        },
        'correct error when there is no matching landing_company';
    $companies->{synthetic} = 'abcd';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'InvalidAccount',
        rule       => $rule_name
        },
        'Fails if the landing company matching market type is different form context landing company';

    $companies->{synthetic} = 'svg';
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Succeeds after setting the same landing company';

    $companies->{financial} = 'maltainvest';
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'Succeeds after setting the same landing company';

    subtest 'affiliate type' => sub {
        $mock_countries->redefine(
            gaming_company_for_country    => sub { return undef },
            financial_company_for_country => sub { return undef });

        $args->{account_type} = 'affiliate';
        $args->{category}     = 'wallet';
        is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
            {
            error_code => 'InvalidAccount',
            rule       => $rule_name
            },
            'correct error when there is no landing_company';

        $mock_countries->redefine(
            gaming_company_for_country    => sub { return $companies->{synthetic} },
            financial_company_for_country => sub { return $companies->{financial} },
            wallet_companies_for_country  => sub { return ['dsl'] });

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
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(restricted_country => sub { return $is_restricted });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'InvalidResidence',
        rule       => $rule_name
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

    my $is_restricted = my $mock_countries = Test::MockModule->new('Brands::Countries');
    my $wallet_lc;
    $mock_countries->redefine(
        wallet_companies_for_country => sub {
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
        error_code => 'InvalidResidence',
        rule       => $rule_name
        },
        'correct error when the account type is disabled';

    $wallet_lc = 'svg';
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'rule apples if wallet landing company is not empty';

    $mock_countries->unmock_all;
};

subtest 'rule residence.is_signup_allowed' => sub {
    my $rule_name = 'residence.is_signup_allowed';

    like exception { $rule_engine->apply_rules($rule_name) }, qr/Either residence or loginid is required/, 'loginid is required';
    my $args = {residence => 'es'};

    my $is_allowed     = 0;
    my $mock_countries = Test::MockModule->new('Brands::Countries');
    $mock_countries->redefine(is_signup_allowed => sub { return $is_allowed });

    is_deeply exception { $rule_engine->apply_rules($rule_name, %$args) },
        {
        error_code => 'InvalidAccount',
        rule       => $rule_name
        },
        'correct error when signup is not allowed';
    $is_allowed = 1;
    lives_ok { $rule_engine->apply_rules($rule_name, %$args) } 'rule apples if signup is allowed';

    $mock_countries->unmock_all;
};

done_testing;
