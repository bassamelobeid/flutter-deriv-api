use strict;
use warnings;

use Date::Utility;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Warnings;

use Client::Account;

use BOM::Platform::Runtime;
use BOM::Platform::Client::CashierValidation;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my ($generic_err_code, $new_email, $vr_client, $cr_client, $cr_client_jpy, $mlt_client, $mf_client, $mx_client, $jp_client) = ('CashierForwardError');

subtest prepare => sub {
    $new_email = 'test' . rand . '@binary.com';
    $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $new_email,
    });

    $new_email = 'test' . rand . '@binary.com';
    $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $new_email,
    });

    $new_email     = 'test' . rand . '@binary.com';
    $cr_client_jpy = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $new_email,
    });

    $new_email  = 'test' . rand . '@binary.com';
    $mlt_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
        email       => $new_email,
    });

    $new_email = 'test' . rand . '@binary.com';
    $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
        email       => $new_email,
    });

    $new_email = 'test' . rand . '@binary.com';
    $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        email       => $new_email,
    });

    $new_email = 'test' . rand . '@binary.com';
    $jp_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'JP',
        email       => $new_email,
    });

    pass "Prepration successful";
};

subtest 'Check cashier suspended' => sub {
    BOM::Platform::Runtime->instance->app_config->system->suspend->system(1);
    my $res = BOM::Platform::Client::CashierValidation::validate($vr_client->loginid, 'deposit');
    is_deeply({
            error => {
                code              => $generic_err_code,
                message_to_client => 'Sorry, cashier is temporarily unavailable due to system maintenance.'
            }
        },
        $res,
        'Correct structure for error response'
    );
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, cashier is temporarily unavailable due to system maintenance.', 'Correct error message';
    BOM::Platform::Runtime->instance->app_config->system->suspend->system(0);

    BOM::Platform::Runtime->instance->app_config->system->suspend->payments(1);
    $res = BOM::Platform::Client::CashierValidation::validate($vr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, cashier is temporarily unavailable due to system maintenance.', 'Correct error message';
    BOM::Platform::Runtime->instance->app_config->system->suspend->payments(0);

    BOM::Platform::Runtime->instance->app_config->system->suspend->cryptocashier(1);
    ok BOM::Platform::Client::CashierValidation::is_crypto_cashier_suspended, 'crpto cashier suspended';
    BOM::Platform::Runtime->instance->app_config->system->suspend->cryptocashier(0);
};

subtest 'Cashier validation common' => sub {
    my $res = BOM::Platform::Client::CashierValidation::validate('CR332112', 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for invalid loginid';
    is $res->{error}->{message_to_client}, 'Invalid account.', 'Correct error message for invalid loginid';

    $res = BOM::Platform::Client::CashierValidation::validate($vr_client->loginid, 'withdraw');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'This is a virtual-money account. Please switch to a real-money account to access cashier.',
        'Correct error message';

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
    is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';

    my $country = $cr_client->residence;
    $cr_client->set_default_account('USD');
    $cr_client->residence('');
    $cr_client->save();

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'withdraw');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for no residence';
    is $res->{error}->{message_to_client}, 'Please set your country of residence.', 'Correct error message for no residence';

    $cr_client->residence($country);
    $cr_client->set_status('cashier_locked', 'system', 'pending investigations');
    $cr_client->save();

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code if client is cashier locked';
    is $res->{error}->{message_to_client}, 'Your cashier is locked.', 'Correct error message if client is cashier locked';

    $cr_client->clr_status('cashier_locked');
    $cr_client->set_status('disabled', 'system', 'pending investigations');
    $cr_client->save();

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code as its disabled';
    is $res->{error}->{message_to_client}, 'Your account is disabled.', 'Correct error message as its disabled';

    $cr_client->clr_status('disabled');
    $cr_client->cashier_setting_password('abc123');
    $cr_client->save();

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for cashier locked';
    is $res->{error}->{message_to_client}, 'Your cashier is locked as per your request.', 'Correct error message for cashier locked';

    $cr_client->cashier_setting_password('');
    $cr_client->save();

    $cr_client_jpy->set_default_account('JPY');
    $cr_client_jpy->save();

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client_jpy->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for invalid account currency';
    is $res->{error}->{message_to_client}, 'JPY transactions may not be performed with this account.',
        'Correct error message for invalid account currency';

    ok !$cr_client->documents_expired, "No documents so nothing to expire";
    my ($doc) = $cr_client->add_client_authentication_document({
        document_type              => "Passport",
        document_format            => "PDF",
        document_path              => '/tmp/test.pdf',
        expiration_date            => '2025-10-10',
        authentication_method_code => 'ID_DOCUMENT'
    });
    $doc->expiration_date('2008-03-03');
    $cr_client->save;

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for expired documents';
    is $res->{error}->{message_to_client},
        'Your identity documents have passed their expiration date. Kindly send a scan of a valid identity document to support@binary.com to unlock your cashier.',
        'Correct error message for expired documents';

    $doc->expiration_date(Date::Utility->new()->plus_time_interval('1d')->date);
    $cr_client->save;
};

subtest 'Cashier validation deposit' => sub {
    $cr_client->set_status('unwelcome', 'system', 'pending investigations');
    $cr_client->save();

    my $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for unwelcome client';
    is $res->{error}->{message_to_client}, 'Your account is restricted to withdrawals only.', 'Correct error message for unwelcome client';

    $cr_client->clr_status('unwelcome');
    $cr_client->save();
};

subtest 'Cashier validation withdraw' => sub {
    $cr_client->set_status('withdrawal_locked', 'system', 'pending investigations');
    $cr_client->save();

    my $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'withdraw');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for withdrawal locked';
    is $res->{error}->{message_to_client}, 'Your account is locked for withdrawals.', 'Correct error message for withdrawal locked';

    $cr_client->clr_status('withdrawal_locked');
    $cr_client->save();
};

subtest 'Cashier validation landing company and country specific' => sub {
    subtest 'maltainvest' => sub {
        my $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
        is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';

        $mf_client->set_default_account('EUR');
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_AUTHENTICATE', 'Correct error code for not authenticated';
        is $res->{error}->{message_to_client}, 'Please authenticate your account.', 'Correct error message for not authenticated';

        my $mock_client = Test::MockModule->new('Client::Account');
        $mock_client->mock(client_fully_authenticated => sub { note "mocked Client->client_fully_authenticated returning true"; 1 });

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_FINANCIAL_RISK_APPROVAL',          'Correct error code';
        is $res->{error}->{message_to_client}, 'Financial Risk approval is required.', 'Correct error message';

        $mf_client->set_status('financial_risk_approval', 'system', 'Accepted approval');
        $mf_client->save();

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_TIN_INFORMATION', 'Correct error code';
        is $res->{error}->{message_to_client},
            'Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
            'Correct error message';

        $mf_client->tax_residence($mf_client->residence);
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_TIN_INFORMATION',
            'Correct error code as tax identification number is also needed for database trigger to set status';

        $mf_client->tax_identification_number('111-222-333');
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res, undef, 'Validation passed';

        $mf_client->tax_residence(undef);
        $mf_client->tax_identification_number(undef);
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res, undef, 'Validation passed, making tax residence undef will not delete status';

        $mock_client->unmock('client_fully_authenticated');
    };

    subtest 'gb as residence' => sub {
        my $res = BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
        is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';

        $mx_client->set_default_account('GBP');
        $mx_client->residence('gb');
        $mx_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_UK_FUNDS_PROTECTION',         'Correct error code';
        is $res->{error}->{message_to_client}, 'Please accept Funds Protection.', 'Correct error message';

        $mx_client->set_status('ukgc_funds_protection',            'system', '1');
        $mx_client->set_status('ukrts_max_turnover_limit_not_set', 'system', '1');
        $mx_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET', 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.',
            'Correct error message';

        $mx_client->clr_status('ukrts_max_turnover_limit_not_set');
        $mx_client->save;

        is BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit'), undef, 'Validation passed';
    };

    subtest 'jp as residence' => sub {
        my $res = BOM::Platform::Client::CashierValidation::validate($jp_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
        is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';

        $jp_client->set_default_account('JPY');
        $jp_client->save;

        is BOM::Platform::Client::CashierValidation::validate($jp_client->loginid, 'deposit'), undef,
            'Validation passed as its per residence not per landing company';

        $jp_client->residence('jp');
        $jp_client->set_status('jp_knowledge_test_pending', 'system', 'pending test');
        $jp_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($jp_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_JP_KNOWLEDGE_TEST', 'Correct error code';
        is $res->{error}->{message_to_client}, 'You must complete the knowledge test to activate this account.', 'Correct error message';

        $jp_client->clr_status('jp_knowledge_test_pending');
        $jp_client->set_status('jp_knowledge_test_fail', 'system', 'pending test');
        $jp_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($jp_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_JP_KNOWLEDGE_TEST', 'Correct error code';
        is $res->{error}->{message_to_client}, 'You must complete the knowledge test to activate this account.', 'Correct error message';

        $jp_client->clr_status('jp_knowledge_test_fail');
        $jp_client->set_status('jp_activation_pending', 'system', 'pending test');
        $jp_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($jp_client->loginid, 'deposit');
        is $res->{error}->{code},              'JP_NOT_ACTIVATION',      'Correct error code';
        is $res->{error}->{message_to_client}, 'Account not activated.', 'Correct error message';

        $jp_client->clr_status('jp_activation_pending');
        $jp_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($jp_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_AGE_VERIFICATION',            'Correct error code';
        is $res->{error}->{message_to_client}, 'Account needs age verification.', 'Correct error message';

        $jp_client->set_status('age_verification', 'system', 1);
        $jp_client->save;

        is BOM::Platform::Client::CashierValidation::validate($jp_client->loginid, 'deposit'), undef, 'Validation passed as age verified';

        $jp_client->clr_status('age_verification');
        my ($doc) = $jp_client->add_client_authentication_document({
            document_type              => "Passport",
            document_format            => "PDF",
            document_path              => '/tmp/test.pdf',
            expiration_date            => '2025-10-10',
            authentication_method_code => 'ID_DOCUMENT'
        });
        $doc->expiration_date(Date::Utility->new()->plus_time_interval('1d')->date);
        $jp_client->save;

        is BOM::Platform::Client::CashierValidation::validate($jp_client->loginid, 'deposit'), undef,
            'Validation passed as not age verified but has valid documents';
    };

    subtest 'pre withdrawal validation' => sub {
        my $res = BOM::Platform::Client::CashierValidation::pre_withdrawal_validation('CR332112', undef);
        is $res->{error}->{code}, $generic_err_code, 'Correct error code';
        is $res->{error}->{message_to_client}, 'Invalid amount.', 'Correct error message';

        $res = BOM::Platform::Client::CashierValidation::pre_withdrawal_validation('CR332112', 100);
        is $res->{error}->{code}, $generic_err_code, 'Correct error code';
        is $res->{error}->{message_to_client}, 'Invalid account.', 'Correct error message';

        $res = BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mlt_client->loginid, 1000);
        is $res->{error}->{code}, $generic_err_code, 'Correct error code';
        is $res->{error}->{message_to_client}, 'Account needs age verification.', 'Correct error message';

        $mlt_client->set_status('age_verification', 'system', 1);
        $mlt_client->save;

        $res = BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mlt_client->loginid, 2000);
        is $res->{error}->{code}, $generic_err_code, 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please authenticate your account.', 'Correct error message';
        is BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mlt_client->loginid, 1999), undef,
            'Amount less than allowed limit hence validation passed';

        $res = BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mx_client->loginid, 1000);
        is $res->{error}->{code}, $generic_err_code, 'Correct error code';
        is $res->{error}->{message_to_client}, 'Account needs age verification.', 'Correct error message';

        $mx_client->set_status('age_verification', 'system', 1);
        $mx_client->save;

        $res = BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mx_client->loginid, 3000);
        is $res->{error}->{code}, $generic_err_code, 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please authenticate your account.', 'Correct error message';

        is BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($cr_client->loginid, 10000), undef,
            'Not applicable for CR hence validation passed';

        my $mock_client = Test::MockModule->new('Client::Account');
        $mock_client->mock(client_fully_authenticated => sub { note "mocked Client->client_fully_authenticated returning true"; 1 });

        is BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mlt_client->loginid, 10000), undef,
            'Fully authenticated and age verified hence passed';
        is BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mx_client->loginid, 10000), undef,
            'Fully authenticated and age verified hence passed';

        $mock_client->unmock('client_fully_authenticated');
    };
};

done_testing();
