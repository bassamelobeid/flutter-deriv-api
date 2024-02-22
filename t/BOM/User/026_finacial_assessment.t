use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Fatal qw(exception lives_ok);
use Test::MockModule;
use Future;
use List::Util      qw(first);
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Helper::Client qw(invalidate_object_cache);
use BOM::User::SocialResponsibility;
use BOM::User::FinancialAssessment qw(is_section_complete build_financial_assessment update_financial_assessment should_warn appropriateness_tests);

my $email_cr = 'test-cr-fa' . '@binary.com';
my $email_mf = 'test-mf-fa' . '@binary.com';

my $user = BOM::User->create(
    email    => $email_cr,
    password => 'hello'
);

my $user_mf = BOM::User->create(
    email    => $email_mf,
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

$user->add_client($client_cr_1);

$user_mf->add_client($client_mf_1);
$user_mf->add_client($client_mf_2);

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

    invalidate_object_cache($client_cr_1);
    lives_ok { $is_financial_assessment_complete = $client_cr_1->is_financial_assessment_complete(); }
    'is_financial_assessment_complete is needed';
    is $is_financial_assessment_complete, 0, 'FI is required for high sr risk';

    lives_ok { BOM::User::SocialResponsibility->update_sr_risk_status($id, 'low'); } ' low sr_risk_status saved';
    invalidate_object_cache($client_cr_1);

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

sub create_user {
    my $hash_pwd = BOM::User::Password::hashpw('passW0rd');
    my $email    = 'test' . rand(999) . '@binary.com';

    return BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );
}

sub create_client {
    my $user     = shift;
    my $currency = shift;

    my $client_details = {
        broker_code              => 'CR',
        residence                => 'au',
        client_password          => 'x',
        last_name                => 'test',
        first_name               => 'tee',
        email                    => 'test@regentmarkets.com',
        salutation               => 'Ms',
        address_line_1           => 'ADDR 1',
        address_city             => 'Segamat',
        phone                    => '+60123456789',
        secret_question          => "Mother's maiden name",
        secret_answer            => 'blah',
        non_pep_declaration_time => Date::Utility->new('20010108')->date_yyyymmdd,
    };

    my $client = $user->create_client(%$client_details, @_);
    $client->set_default_account($currency) if $currency;

    return $client;
}

subtest 'Check clear withdrawallock from sibling account when financial assessment is updated' => sub {

    my $financial_information = {
        "employment_industry" => "Finance",
        "education_level"     => "Secondary",
        "income_source"       => "Self-Employed",
        "net_income"          => '$25,000 - $50,000',
        "estimated_worth"     => '$100,000 - $250,000',
        "occupation"          => 'Senior Manager',
        "employment_status"   => "Self-Employed",
        "source_of_wealth"    => "Company Ownership",
        "account_turnover"    => 'Less than $25,000'
    };
    my $updated_fa;
    my $user_fa    = create_user();
    my $usd_client = create_client($user_fa, 'USD');
    my $btc_client = create_client($user_fa, 'BTC');
    my $eth_client = create_client($user_fa, 'ETH');
    $usd_client->status->set('mt5_withdrawal_locked', 'test', 'FA is required for the first deposit on regulated MT5.');
    $btc_client->status->set('mt5_withdrawal_locked', 'test', 'FA is required for the first deposit on regulated MT5.');
    $eth_client->status->set('mt5_withdrawal_locked', 'test', 'FA is required for the first deposit on regulated MT5.');
    update_financial_assessment($user_fa, $financial_information);
    ok !$usd_client->status->mt5_withdrawal_locked, 'withdrawal locked removed after updating financial information';
    ok !$btc_client->status->mt5_withdrawal_locked, 'withdrawal locked removed after updating financial information';
    ok !$eth_client->status->mt5_withdrawal_locked, 'withdrawal locked removed after updating financial information';
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

subtest 'update_financial_assessment' => sub {
    my $financial_information = {
        "employment_industry" => "Finance",
        "education_level"     => "Secondary",
        "income_source"       => "Self-Employed",
        "net_income"          => '$25,000 - $50,000',
        "estimated_worth"     => '$100,000 - $250,000',
        "occupation"          => 'Senior Manager',
        "employment_status"   => "Self-Employed",
        "source_of_wealth"    => "Company Ownership",
        "account_turnover"    => 'Less than $25,000'
    };
    my $updated_fa;

    # CR user
    update_financial_assessment($user, $financial_information);
    $updated_fa = decode_json_utf8($client_cr_1->get_financial_assessment);
    is $updated_fa->{'occupation'}, 'Senior Manager', 'Financial assessment was unpdated';

    # MF user
    my $mocked_maltainvest_fa = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);
    $mocked_maltainvest_fa->{'occupation'} = 'Senior Manager';
    update_financial_assessment($user_mf, $mocked_maltainvest_fa);
    $updated_fa = decode_json_utf8($client_mf_1->get_financial_assessment);
    is $updated_fa->{'occupation'}, 'Senior Manager', 'Financial assessment was unpdated';
};

subtest 'build_financial_assessment' => sub {

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
    my $financial_assessment;

    $financial_assessment = build_financial_assessment();
    is $financial_assessment->{scores}->{total_score}, 0, 'Financial information not provided';

    $financial_assessment = build_financial_assessment($financial_information);
    is $financial_assessment->{scores}->{total_score}, 18, 'Only financial information is provided';

    my $mocked_te = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_set_fa()->{trading_experience_regulated};
    $financial_assessment = build_financial_assessment($mocked_te);
    is $financial_assessment->{scores}->{total_score}, 10, 'Only trading experience is provided';

    my $mocked_maltainvest_fa = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);
    $financial_assessment = build_financial_assessment($mocked_maltainvest_fa);
    is $financial_assessment->{scores}->{total_score}, 28, 'Financial information and trading experience are provided';

};

subtest 'should_warn' => sub {
    my $mocked_maltainvest_fa = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);

    my $should_warn = should_warn($mocked_maltainvest_fa);
    ok !$should_warn, 'Trading score is greater or equal to 8';

    my $mocked_maltainvest_fi = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_set_fa()->{financial_information};
    $should_warn = should_warn($mocked_maltainvest_fi);
    ok $should_warn, 'Trading score is less than 8 and CFD score is less than 4';

};

subtest 'appropriateness_tests' => sub {
    my $mocked_maltainvest_fa = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);
    my $appropriateness_tests;
    $appropriateness_tests = appropriateness_tests($client_mf_1, $mocked_maltainvest_fa);
    is $appropriateness_tests->{result}, 1, "Passed appropriateness first questions";

    $mocked_maltainvest_fa->{accept_risk} = 1;
    $appropriateness_tests = appropriateness_tests($client_mf_1, $mocked_maltainvest_fa);
    is $appropriateness_tests->{result}, 1, "Accepted risk";

    delete $mocked_maltainvest_fa->{risk_tolerance};
    $appropriateness_tests = appropriateness_tests($client_mf_1, $mocked_maltainvest_fa);
    is $appropriateness_tests->{result}, 0, "Failed appropriateness first questions";

    my $expected_result = $appropriateness_tests;
    $mocked_maltainvest_fa->{risk_tolerance} = "Yes";
    $appropriateness_tests = appropriateness_tests($client_mf_1, $mocked_maltainvest_fa);
    cmp_deeply $appropriateness_tests, $expected_result, "still in cooldown period";

    my $mocked_redis_db = Test::MockModule->new('RedisDB');

    # To unlock account after cooldown period (1day)
    $mocked_redis_db->mock(
        ttl => sub {
            my ($self, $key) = @_;
            return 0;
        });

    $appropriateness_tests = appropriateness_tests($client_mf_1, $mocked_maltainvest_fa);
    is $appropriateness_tests->{result}, 1, "Passed appropriateness first questions after cooldown";
    $mocked_redis_db->unmock_all();

};

done_testing();
