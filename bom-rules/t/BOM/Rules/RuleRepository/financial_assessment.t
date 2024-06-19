use strict;
use warnings;

use Test::Most;
use Test::Fatal;
use Test::MockModule;
use Test::Deep;

use BOM::Rules::Engine;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
my $redis          = BOM::Config::Redis::redis_replicated_write();
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
my %financial_data_mf = (
    "risk_tolerance"                           => "Yes",
    "source_of_experience"                     => "I have an academic degree, professional certification, and/or work experience.",
    "cfd_experience"                           => "Less than a year",
    "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
    "trading_experience_financial_instruments" => "Less than a year",
    "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
    "cfd_trading_definition"                   => "Speculate on the price movement.",
    "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
    "leverage_trading_high_risk_stop_loss"     => "Close your trade automatically when the loss is more than or equal to a specific amount.",
    "required_initial_margin"                  => "When opening a Leveraged CFD trade.",
    "employment_industry"                      => "Finance",
    "education_level"                          => "Secondary",
    "income_source"                            => "Self-Employed",
    "net_income"                               => '$25,000 - $50,000',
    "estimated_worth"                          => '$100,000 - $250,000',
    "account_turnover"                         => '$25,000 - $50,000',
    "occupation"                               => 'Managers',
    "employment_status"                        => "Self-Employed",
    "source_of_wealth"                         => "Company Ownership",
);

my %financial_data_mf_fail = (
    "risk_tolerance"                           => "Yes",
    "source_of_experience"                     => "I have no knowledge.",
    "cfd_experience"                           => "No experience",
    "cfd_frequency"                            => "1 - 5 transactions in the past 12 months",
    "trading_experience_financial_instruments" => "No experience",
    "trading_frequency_financial_instruments"  => "1 - 5 transactions in the past 12 months",
    "cfd_trading_definition"                   => "Speculate on the price movement.",
    "leverage_impact_trading"                  => "Leverage lets you open larger positions for a fraction of the trade's value.",
    "leverage_trading_high_risk_stop_loss"     => "Close your trade automatically when the loss is more than or equal to a specific amount.",
    "required_initial_margin"                  => "When opening a Leveraged CFD trade.",
    "employment_industry"                      => "Finance",
    "education_level"                          => "Secondary",
    "income_source"                            => "Self-Employed",
    "net_income"                               => '$25,000 - $50,000',
    "estimated_worth"                          => '$100,000 - $250,000',
    "account_turnover"                         => '$25,000 - $50,000',
    "occupation"                               => 'Managers',
    "employment_status"                        => "Self-Employed",
    "source_of_wealth"                         => "Company Ownership",
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
    trading_mf => [
        qw/
            occupation
            education_level
            source_of_wealth
            estimated_worth
            account_turnover
            employment_industry
            income_source
            net_income
            employment_status
            risk_tolerance
            source_of_experience
            cfd_experience
            cfd_frequency
            trading_experience_financial_instruments
            trading_frequency_financial_instruments
            cfd_trading_definition
            leverage_impact_trading
            leverage_trading_high_risk_stop_loss
            required_initial_margin/
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

my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
my $user_mf = BOM::User->create(
    email          => 'rule_financial_assessment_mf@binary.com',
    password       => 'abcd',
    email_verified => 1,
);
$user_mf->add_client($client_mf);

subtest 'rule financial_assessment.required_sections_are_complete' => sub {
    my $rule_name = 'financial_assessment.required_sections_are_complete';

    my $engine            = BOM::Rules::Engine->new(client => $client);
    my @landing_companies = qw/svg maltainvest/;
    like
        exception { $engine->apply_rules($rule_name) },
        qr/Client loginid is missing/,
        "Correct error for empty args";

    my @keys = $assessment_keys->{trading_experience}->@*;
    my %args = {%financial_data}->%{@keys};

    is_deeply(
        exception { $engine->apply_rules($rule_name, %args, landing_company => $_, loginid => $client->loginid) },
        {
            error_code => 'IncompleteFinancialAssessment',
            rule       => $rule_name
        },
        "Correct error for trading experience only - $_"
    ) for @landing_companies;

    @keys = $assessment_keys->{financial_info}->@*;
    %args = {%financial_data}->%{@keys};
    lives_ok { $engine->apply_rules($rule_name, %args, landing_company => $_, loginid => $client->loginid) }
    "Financial assessment is complete with financial info only - $_" for (qw/svg/);
    is_deeply(
        exception { $engine->apply_rules($rule_name, %args, landing_company => 'maltainvest', loginid => $client->loginid) },
        {
            error_code => 'IncompleteFinancialAssessment',
            rule       => $rule_name
        },
        "Correct error for financial info only - maltainvest"
    );
    @landing_companies = qw/svg/;

    lives_ok { $engine->apply_rules($rule_name, %financial_data, landing_company => $_, loginid => $client->loginid) }
    "Financial assessment is complete with all data - $_" for @landing_companies;

    my @landing_companies_mf = qw/maltainvest/;
    my $engine_mf            = BOM::Rules::Engine->new(client => $client_mf);
    @keys = $assessment_keys->{trading_mf}->@*;
    %args = {%financial_data_mf}->%{@keys};
    lives_ok { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid) }
    "Financial assessment is complete with all data - $_" for @landing_companies_mf;

    my @sections = ("financial_information");
    lives_ok { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid, keys => \@sections) }
    "Financial assessment is complete with financial_information - $_" for @landing_companies_mf;

    @sections = ("trading_experience_regulated");
    lives_ok { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid, keys => \@sections) }
    "Financial assessment is complete with trading_experience_regulated - $_" for @landing_companies_mf;

    @sections = ("trading_experience_regulated", "financial_information");
    lives_ok { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid, keys => \@sections) }
    "Financial assessment is complete with all data - $_" for @landing_companies_mf;

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

    #simulation
    $mock_client->redefine(
        'is_financial_assessment_complete' => sub {
            my $self          = shift;
            my $is_withdrwals = shift // 0;
            return $is_withdrwals ? 0 : 1;
        });

    $args{action} = 'withdrawal';
    is_deeply exception { $rule_engine->apply_rules($rule_name, %args) },
        {
        error_code => 'FinancialAssessmentRequired',
        rule       => $rule_name
        },
        'Error for in complete FA for withdrawals';

    $args{action} = 'deposit';
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if FA is compeleted for deposits';

    delete $args{action};
    lives_ok { $rule_engine->apply_rules($rule_name, %args) } 'Test passes if FA is compeleted for default';
    $mock_client->unmock_all;
};

$rule_name = 'financial_asssessment.account_opening_validation';
subtest $rule_name => sub {
    my $rule_engine     = BOM::Rules::Engine->new(client => $client);
    my $landing_company = 'maltainvest';
    like
        exception { $rule_engine->apply_rules($rule_name) },
        qr/Client loginid is missing/,
        "Correct error for empty args";

    my %args = %financial_data_mf;
    lives_ok { $rule_engine->apply_rules($rule_name, %args, landing_company => $landing_company, loginid => $client->loginid) }
    'Test passes for all sections';
    delete $args{cfd_experience};

    $args{account_type} = 'affiliate';
    lives_ok { $rule_engine->apply_rules($rule_name, %args, landing_company => $landing_company, loginid => $client->loginid) }
    'Client account type is affiliate';

    $args{account_type} = 'doughlow';
    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args, landing_company => $landing_company, loginid => $client->loginid) },
        {
            error_code => 'IncompleteFinancialAssessment',
            rule       => $rule_name
        },
        "Test fail when there is a missing trading experience section"
    );
    delete $args{income_source};
    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args, landing_company => $landing_company, loginid => $client->loginid) },
        {
            error_code => 'IncompleteFinancialAssessment',
            rule       => $rule_name
        },
        "Test fail when there is a missing trading experience and financial information sections"
    );
    $args{cfd_experience} = "No experience";
    is_deeply(
        exception { $rule_engine->apply_rules($rule_name, %args, landing_company => $landing_company, loginid => $client->loginid) },
        {
            error_code => 'IncompleteFinancialAssessment',
            rule       => $rule_name
        },
        "Test fail when there is a missing financial information sections"
    );

};

$rule_name = 'financial_asssessment.appropriateness_test';
subtest $rule_name => sub {
    my $engine_mf         = BOM::Rules::Engine->new(client => $client_mf);
    my @landing_companies = qw/svg maltainvest/;
    like
        exception { $engine_mf->apply_rules($rule_name) },
        qr/Client loginid is missing/,
        "Correct error for empty args";

    my @landing_companies_mf = qw/maltainvest/;

    my @keys = $assessment_keys->{trading_mf}->@*;
    my %args = {%financial_data_mf}->%{@keys};
    lives_ok { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid) }
    "appropriateness test is complete with all data - $_" for @landing_companies_mf;

    $args{risk_tolerance} = "No";

    cmp_deeply exception { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid) },
        {
        error_code => 'AppropriatenessTestFailed',
        rule       => $rule_name,
        details    => {cooling_off_expiration_date => re('^[0-9]+$')}
        },
        "appropriateness test failed the first question - $_"
        for @landing_companies_mf;
    $args{risk_tolerance} = "No";
    $redis->del('APPROPRIATENESS_TESTS::COOLING_OFF_PERIOD::' . $client_mf->{binary_user_id});
    $args{accept_risk} = 1;
    cmp_deeply exception { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid) },
        {
        error_code => 'AppropriatenessTestFailed',
        rule       => $rule_name,
        details    => {cooling_off_expiration_date => re('^[0-9]+$')}
        },
        'appropriateness test failed the first question (accept_risk should be disregarded)'
        for @landing_companies_mf;
    $redis->del('APPROPRIATENESS_TESTS::COOLING_OFF_PERIOD::' . $client_mf->{binary_user_id});
    %args = {%financial_data_mf_fail}->%{@keys};
    cmp_deeply exception { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid) },
        {
        error_code => 'AppropriatenessTestFailed',
        rule       => $rule_name
        },
        'appropriateness test failed with no cooldown'
        for @landing_companies_mf;
    $redis->del('APPROPRIATENESS_TESTS::COOLING_OFF_PERIOD::' . $client_mf->{binary_user_id});
    $args{accept_risk} = 0;
    cmp_deeply exception { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid) },
        {
        error_code => 'AppropriatenessTestFailed',
        rule       => $rule_name,
        details    => {cooling_off_expiration_date => re('^[0-9]+$')}
        },
        'appropriateness test failed with cooldown'
        for @landing_companies_mf;

    $args{accept_risk} = 1;

    cmp_deeply exception { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid) },
        {
        error_code => 'AppropriatenessTestFailed',
        rule       => $rule_name,
        details    => {cooling_off_expiration_date => re('^[0-9]+$')}
        },
        'appropriateness failed - waiting for cooldown'
        for @landing_companies_mf;

    $redis->del('APPROPRIATENESS_TESTS::COOLING_OFF_PERIOD::' . $client_mf->{binary_user_id});

    lives_ok { $engine_mf->apply_rules($rule_name, %args, landing_company => $_, loginid => $client_mf->loginid) }
    "appropriateness failed but accepted the risk - $_" for @landing_companies_mf;
};

done_testing();
