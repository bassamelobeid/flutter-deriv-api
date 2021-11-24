use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;

use BOM::Rules::Engine;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

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

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $user = BOM::User->create(
    email          => 'rule_financial_assessment@binary.com',
    password       => 'abcd',
    email_verified => 1,
);
$user->add_client($client);

subtest 'rule financial_assessment.required_sections_are_complete' => sub {
    my $rule_name = 'financial_assessment.required_sections_are_complete';

    my $engine            = BOM::Rules::Engine->new();
    my @landing_companies = qw/svg malta iom maltainvest/;

    like
        exception { $engine->apply_rules($rule_name) },
        qr/Either landing_company or loginid is required/,
        "Correct error for empty args";

    my @keys = $assessment_keys->{trading_experience}->@*;
    my %args = {%financial_data}->%{@keys};
    is_deeply(
        exception { $engine->apply_rules($rule_name, %args, landing_company => $_) },
        {
            error_code => 'IncompleteFinancialAssessment',
            rule       => $rule_name
        },
        "Correct error for trading experience only - $_"
    ) for @landing_companies;

    @keys = $assessment_keys->{financial_info}->@*;
    %args = {%financial_data}->%{@keys};
    lives_ok { $engine->apply_rules($rule_name, %args, landing_company => $_) } "Financial assessment is complete with financial info only - $_"
        for (qw/svg malta iom/);
    is_deeply(
        exception { $engine->apply_rules($rule_name, %args, landing_company => 'maltainvest') },
        {
            error_code => 'IncompleteFinancialAssessment',
            rule       => $rule_name
        },
        "Correct error for financial info only - maltainvest"
    );

    lives_ok { $engine->apply_rules($rule_name, %financial_data, landing_company => $_) } "Financial assessment is complete with all data - $_"
        for @landing_companies;
};

my $rule_name = 'financial_asssessment.completed';
subtest $rule_name => sub {
    my $rule_engine = BOM::Rules::Engine->new(client => $client);

    my %args = (loginid => $client->loginid);

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->redefine(is_financial_assessment_complete => 0);
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'FinancialAssessmentRequired',
        rule       => $rule_name
        },
        'Error for in complete FA';

    $mock_client->redefine(is_financial_assessment_complete => 1);
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if FA is compeleted';

    $mock_client->unmock_all;
};

done_testing();
