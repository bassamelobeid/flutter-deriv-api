use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal qw(exception lives_ok);
use Future;
use List::Util      qw(first);
use JSON::MaybeUTF8 qw(encode_json_utf8);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;
use BOM::User::SocialResponsibility;
use BOM::User::FinancialAssessment qw(is_section_complete);

my $email_cr = 'test-cr-fa' . '@binary.com';
my $email_mf = 'test-mf-fa' . '@binary.com';

my $user = BOM::User->create(
    email    => $email_cr,
    password => 'hello'
);

my $id          = $user->id;
my $client_cr_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $id
});

my $client_mf_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $client_mf_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

subtest 'CR is_financial_assessment_complete' => sub {

    my $financial_information = {
        "employment_industry" => "Finance",                # +15
        "education_level"     => "Secondary",              # +1
        "income_source"       => "Self-Employed",          # +0
        "net_income"          => '$25,000 - $50,000',      # +1
        "estimated_worth"     => '$100,000 - $250,000',    # +1
        "occupation"          => 'Managers',               # +0
        "employment_status"   => "Self-Employed",          # +0
        "source_of_wealth"    => "Company Ownership",      # +0
        "account_turnover"    => 'Less than $25,000'
    };
    my $is_financial_assessment_complete;

    lives_ok { $is_financial_assessment_complete = $client_cr_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is not needed';
    is $is_financial_assessment_complete, 1, 'FI is not required for low aml risk';

    lives_ok { BOM::User::SocialResponsibility->update_sr_risk_status($id, 'high'); } 'high sr_risk_status saved';

    lives_ok { $is_financial_assessment_complete = $client_cr_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is needed';
    is $is_financial_assessment_complete, 0, 'FI is required for high sr risk';

    lives_ok { BOM::User::SocialResponsibility->update_sr_risk_status($id, 'low'); } ' low sr_risk_status saved';

    $client_cr_1->status->set('allow_document_upload', 'system', 'BECOME_HIGH_RISK');
    $client_cr_1->status->set('withdrawal_locked',     'system', 'BECOME_HIGH_RISK');

    lives_ok { $is_financial_assessment_complete = $client_cr_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is needed';
    is $is_financial_assessment_complete, 0, 'FI is required for accounts was_locked_for_high_risk';

    $client_cr_1->status->clear_allow_document_upload();
    $client_cr_1->status->clear_withdrawal_locked();
    $client_cr_1->aml_risk_classification('standard');

    lives_ok { $is_financial_assessment_complete = $client_cr_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is not needed';
    is $is_financial_assessment_complete, 1, 'FI is not required for standard aml risk';

    $client_cr_1->aml_risk_classification('high');

    lives_ok { $is_financial_assessment_complete = $client_cr_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is needed';
    is $is_financial_assessment_complete, 0, 'FI is required for high aml risk ';

    $client_cr_1->financial_assessment({
        data => encode_json_utf8($financial_information),
    });
    $client_cr_1->save();

    lives_ok { $is_financial_assessment_complete = $client_cr_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is needed';
    is $is_financial_assessment_complete, 1, 'FI is completed for high risk of';

};

subtest 'MF is_financial_assessment_complete' => sub {

    my $TE_only = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_set_fa()->{trading_experience_regulated};
    my $FA      = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);

    my $is_financial_assessment_complete;

    lives_ok { $is_financial_assessment_complete = $client_mf_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is  needed';
    is $is_financial_assessment_complete, 0, 'TE is required for low aml risk';

    $client_mf_1->aml_risk_classification('standard');
    lives_ok { $is_financial_assessment_complete = $client_mf_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is  needed';
    is $is_financial_assessment_complete, 0, 'TE is required for standard aml risk';

    $client_mf_1->aml_risk_classification('high');
    lives_ok { $is_financial_assessment_complete = $client_mf_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is  needed';
    is $is_financial_assessment_complete, 0, 'TE is required for high aml risk';

    $client_mf_1->aml_risk_classification('standard');
    $client_mf_1->financial_assessment({
        data => encode_json_utf8($TE_only),
    });
    $client_mf_1->save();

    lives_ok { $is_financial_assessment_complete = $client_mf_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is needed';
    is $is_financial_assessment_complete, 1, 'TE is completed for standard risk';

    lives_ok { $is_financial_assessment_complete = $client_mf_1->is_financial_assessment_complete(1); }
    'is_financial_assessment_complete is needed for withdrawals';
    is $is_financial_assessment_complete, 0, 'TE is completed for standard risk but no FA for withdrawals';

    $client_mf_1->financial_assessment({
        data => encode_json_utf8($FA),
    });
    $client_mf_1->save();

    lives_ok { $is_financial_assessment_complete = $client_mf_1->is_financial_assessment_complete(1); }
    'is_financial_assessment_complete is needed for withdrawals';
    is $is_financial_assessment_complete, 1, 'TE and FA is completed for standard risk for withdrawals';

    lives_ok { $is_financial_assessment_complete = $client_mf_2->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is needed';
    is $is_financial_assessment_complete, 0, 'TE is required for low aml risk';

    $client_mf_2->aml_risk_classification('high');
    $client_mf_2->financial_assessment({
        data => encode_json_utf8($TE_only),
    });
    $client_mf_2->save();
    lives_ok { $is_financial_assessment_complete = $client_mf_2->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is  needed';
    is $is_financial_assessment_complete, 1, 'TE is required for high aml risk';

    lives_ok { $is_financial_assessment_complete = $client_mf_2->is_financial_assessment_complete(1); }
    'is_financial_assessment_complete is needed for withdrawals';
    is $is_financial_assessment_complete, 0, 'TE is completed for high risk but no FA for withdrawals';
    $client_mf_2->financial_assessment({
        data => encode_json_utf8($FA),
    });
    $client_mf_2->save();

    lives_ok { $is_financial_assessment_complete = $client_mf_2->is_financial_assessment_complete(1); }
    'is_financial_assessment_complete is needed for withdrawals';
    is $is_financial_assessment_complete, 1, 'TE and FA is completed for high risk for withdrawals';
};

subtest 'is_section_complete' => sub {
    my $financial_assessment = {
        "employment_industry" => "Finance",
        "education_level"     => "Primary",
        "income_source"       => "Self-Employed",
        "net_income"          => '$25,000 - $50,000',
        "estimated_worth"     => '$100,000 - $250,000',
        "occupation"          => 'Managers',
        "employment_status"   => "Self-Employed",
        "source_of_wealth"    => "Company Ownership",
        "account_turnover"    => 'Less than $25,000'
    };
    my $is_section_complete;

    $is_section_complete = is_section_complete($financial_assessment, 'financial_information');

    is $is_section_complete, 1, 'All FI are present';

    delete $financial_assessment->{employment_industry};

    $is_section_complete = is_section_complete($financial_assessment, 'financial_information');

    is $is_section_complete, 0, 'Missing FI information';

    $is_section_complete = is_section_complete($financial_assessment, 'trading_experience');

    is $is_section_complete, 0, 'Missing TE information';

    my $TE_only = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_set_fa()->{trading_experience_regulated};

    $is_section_complete = is_section_complete($TE_only, 'trading_experience', 'maltainvest');

    is $is_section_complete, 1, 'All TE are present';

    delete $TE_only->{risk_tolerance};

    $is_section_complete = is_section_complete($TE_only, 'trading_experience');

    is $is_section_complete, 0, 'Missing TE information';

    my $fa = {
        "binary_options_trading_frequency"     => "0-5 transactions in the past 12 months",
        "forex_trading_experience"             => "0-1 year",
        "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",
        "employment_status"                    => "Self-Employed",
        "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
        "other_instruments_trading_frequency"  => "0-5 transactions in the past 12 months",
        "other_instruments_trading_experience" => "0-1 year",
        "cfd_trading_experience"               => "0-1 year",
        "binary_options_trading_experience"    => "0-1 year"
    };
    $is_section_complete = is_section_complete($fa, 'trading_experience');
    is $is_section_complete, 1, 'All TE are present';

    $is_section_complete = is_section_complete($fa, 'trading_experience', 'maltainvest');
    is $is_section_complete, 0, 'old TE present but cfd score was less than zero';

    $fa->{cfd_trading_experience} = '1-2 years';
    $fa->{cfd_trading_frequency}  = '40 transactions or more in the past 12 months';
    $is_section_complete          = is_section_complete($fa, 'trading_experience', 'maltainvest');
    is $is_section_complete, 1, 'old TE present and cfd score was positive';
};

done_testing();
