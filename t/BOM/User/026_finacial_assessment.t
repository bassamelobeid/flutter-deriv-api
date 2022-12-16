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

done_testing();
