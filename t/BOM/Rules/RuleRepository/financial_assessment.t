use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Rules::Engine;

my %financial_data = (
    "forex_trading_experience"             => "Over 3 years",
    "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
    "binary_options_trading_experience"    => "1-2 years",
    "binary_options_trading_frequency"     => "40 transactions or more in the past 12 months",
    "cfd_trading_experience"               => "1-2 years",
    "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",
    "other_instruments_trading_experience" => "Over 3 years",
    "other_instruments_trading_frequency"  => "6-10 transactions in the past 12 months",
    "employment_industry"                  => "Finance",
    "education_level"                      => "Secondary",
    "income_source"                        => "Self-Employed",
    "net_income"                           => '$25,000 - $50,000',
    "estimated_worth"                      => '$100,000 - $250,000',
    "account_turnover"                     => '$25,000 - $50,000',
    "occupation"                           => 'Managers',
    "employment_status"                    => "Self-Employed",
    "source_of_wealth"                     => "Company Ownership",
);

my $assessment_keys = {
    financial_info => [
        qw/
            occupation
            education_level
            source_of_wealth
            estimated_worth
            account_turnover
            employment_industry
            income_source
            net_income
            employment_status/
    ],
    trading_experience => [
        qw/
            other_instruments_trading_frequency
            other_instruments_trading_experience
            binary_options_trading_frequency
            binary_options_trading_experience
            forex_trading_frequency
            forex_trading_experience
            cfd_trading_frequency
            cfd_trading_experience/
    ],
};

subtest 'rule financial_assessment.required_sections_are_complete' => sub {
    my $rule_name = 'financial_assessment.required_sections_are_complete';

    my %engines = map { $_ => BOM::Rules::Engine->new(landing_company => $_) } (qw/svg malta iom maltainvest/);

    is_deeply(
        exception { $engines{$_}->apply_rules($rule_name) },
        {error_code => 'IncompleteFinancialAssessment'},
        "Correct error for empty args - $_"
    ) for keys %engines;

    my @keys = $assessment_keys->{trading_experience}->@*;
    my %args = {%financial_data}->%{@keys};
    is_deeply(
        exception { $engines{$_}->apply_rules($rule_name, \%args) },
        {error_code => 'IncompleteFinancialAssessment'},
        "Correct error for trading experience only - $_"
    ) for keys %engines;

    @keys = $assessment_keys->{financial_info}->@*;
    %args = {%financial_data}->%{@keys};
    is($engines{$_}->apply_rules($rule_name, \%args), 1, "Financial assessment is complete with financial info only - $_") for (qw/svg malta iom/);
    is_deeply(
        exception { $engines{maltainvest}->apply_rules($rule_name, \%args) },
        {error_code => 'IncompleteFinancialAssessment'},
        "Correct error for financial info only - maltainvest"
    );

    is($engines{$_}->apply_rules($rule_name, \%financial_data), 1, "Financial assessment is complete with all data - $_") for keys %engines;
};

done_testing();
