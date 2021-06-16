use strict;
use warnings;

use Date::Utility;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Warnings;
use Test::Deep;

use ExchangeRates::CurrencyConverter;
use Format::Util::Numbers qw/get_min_unit roundcommon/;

use BOM::User::Client;
use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;
use BOM::Platform::Client::CashierValidation;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my ($generic_err_code, $new_email, $vr_client, $cr_client, $cr_client_2, $mlt_client, $mf_client, $mx_client) = ('CashierForwardError');

my $app_config = BOM::Config::Runtime->instance->app_config;

subtest prepare => sub {
    $new_email = 'test' . rand . '@binary.com';
    my $user_client = BOM::User->create(
        email          => $new_email,
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );

    $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $new_email,
    });
    $vr_client->set_default_account('USD');

    $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $new_email,
        binary_user_id => 1,
    });
    $cr_client_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        email          => $new_email,
        binary_user_id => 1,
    });

    $mlt_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
        email       => $new_email,
    });

    $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
        email       => $new_email,
    });

    $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        email       => $new_email,
    });

    $user_client->add_client($vr_client);
    $user_client->add_client($cr_client);
    $user_client->add_client($cr_client_2);
    $user_client->add_client($mlt_client);
    $user_client->add_client($mf_client);
    $user_client->add_client($mx_client);

    pass "Prepration successful";
};

subtest 'basic tests' => sub {

    my $res = BOM::Platform::Client::CashierValidation::validate($vr_client->loginid, 'withdraw');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'This is a virtual-money account. Please switch to a real-money account to access cashier.',
        'Correct error message';
    is $res->{status}, undef, 'no status';

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
    is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';
    cmp_deeply $res->{status}, ['ASK_CURRENCY'], 'correct status';

    $res = BOM::Platform::Client::CashierValidation::validate('CR332112', 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for invalid loginid';
    is $res->{error}->{message_to_client}, 'Invalid account.', 'Correct error message for invalid loginid';
    cmp_deeply $res->{status}, undef, 'correct status';
};

subtest 'System suspend' => sub {
    $cr_client->set_default_account('USD');
    $cr_client_2->set_default_account('BTC');

    $app_config->system->suspend->payments(1);

    my $res = BOM::Platform::Client::CashierValidation::base_validation($cr_client);
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Payments suspended error for fiat client';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';

    $res = BOM::Platform::Client::CashierValidation::base_validation($cr_client_2);
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Payments suspended error for crypto client';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';

    $app_config->system->suspend->payments(0);

    $app_config->system->suspend->cashier(1);

    $res = BOM::Platform::Client::CashierValidation::base_validation($cr_client);
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Cashier suspended error for fiat client';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';

    $res = BOM::Platform::Client::CashierValidation::base_validation($cr_client_2);
    unlike $res->{error}->{message_to_client} // '', '/cashier is temporarily unavailable/', 'crypto client is unaffected';

    $app_config->system->suspend->cashier(0);

    $app_config->system->suspend->cryptocashier(1);

    $res = BOM::Platform::Client::CashierValidation::base_validation($cr_client_2);
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, crypto cashier is temporarily unavailable due to system maintenance.',
        'Cashier suspended error for crypto client';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';

    $res = BOM::Platform::Client::CashierValidation::base_validation($cr_client);
    unlike $res->{error}->{message_to_client} // '', '/cashier is temporarily unavailable/', 'fiat client is unaffected';

    $app_config->system->suspend->cryptocashier(0);

    $app_config->system->suspend->cryptocurrencies('BTC');
    $res = BOM::Platform::Client::CashierValidation::base_validation($cr_client_2);
    is $res->{error}{message_to_client}, 'Sorry, crypto cashier is temporarily unavailable due to system maintenance.', 'Crypto currency suspended';
    $app_config->system->suspend->cryptocurrencies('');
};

subtest 'Cashier validation common' => sub {

    my $country = $cr_client->residence;
    $cr_client->residence('');
    $cr_client->save();

    my $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'withdraw');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for no residence';
    is $res->{error}->{message_to_client}, 'Please set your country of residence.', 'Correct error message for no residence';
    cmp_deeply $res->{status}, set('no_residence'), 'correct status';

    $cr_client->residence($country);

    $cr_client->status->set('cashier_locked', 'system', 'pending investigations');
    $cr_client->save();

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code if client is cashier locked';
    is $res->{error}->{message_to_client}, 'Your cashier is locked.', 'Correct error message if client is cashier locked';
    cmp_deeply $res->{status}, set('cashier_locked_status'), 'correct status';

    $cr_client->status->clear_cashier_locked;
    $cr_client->status->set('disabled', 'system', 'pending investigations');

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code as its disabled';
    is $res->{error}->{message_to_client}, 'Your account is disabled.', 'Correct error message as its disabled';
    cmp_deeply $res->{status}, set('disabled_status'), 'correct status';

    $cr_client->status->clear_disabled;

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(is_financial_assessment_complete => 0);
    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for financial assessment not complete';
    is $res->{error}->{message_to_client}, 'Please complete the financial assessment form to lift your withdrawal and trading limits.',
        'Correct error message for incomplete FA';
    cmp_deeply $res->{status}, set('FinancialAssessmentRequired'), 'correct status';
    $mock_client->unmock_all();

    ok !$cr_client->documents->expired, "No documents so nothing to expire";

    my ($doc) = $cr_client->add_client_authentication_document({
        document_type              => "passport",
        file_name                  => 'test.pdf',
        document_format            => "PDF",
        document_path              => '/tmp/test.pdf',
        expiration_date            => '2008-03-03',
        authentication_method_code => 'ID_DOCUMENT',
        status                     => 'verified',
        checksum                   => 'CE114E4501D2F4E2DCEA3E17B546F339'
    });
    $cr_client->save;

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, undef, 'Correct error code for expired documents but expired check not required';

    $mock_client->mock(is_document_expiry_check_required => sub { note "mocked Client->is_document_expiry_check_required returning true"; 1 });

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, 'CashierForwardError', 'Correct error code for expired documents with expired check required';
    is $res->{error}->{message_to_client},
        'Your identity documents have expired. Visit your account profile to submit your valid documents and unlock your cashier.',
        'Correct error message for expired documents with expired check required';
    cmp_deeply $res->{status}, set('documents_expired'), 'correct status';
    $mock_client->unmock_all();

    my $new_expiration_date = Date::Utility->new()->plus_time_interval('1d')->date;
    $cr_client->client_authentication_document->[0]->expiration_date($new_expiration_date);
    $cr_client->save;

    # Note: following test assume address_city is a withdrawal requirement for SVG in landing_companies.yml
    my $address_city = $cr_client->address_city;
    $cr_client->address_city('');
    $cr_client->save;

    my $expected = {
        'code'              => 'ASK_FIX_DETAILS',
        'details'           => {'fields' => ['address_city']},
        'message_to_client' => 'Your profile appears to be incomplete. Please update your personal details to continue.'
    };

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'withdraw');
    is_deeply($res->{error}, $expected, 'lc withdrawal requirements validated');
    cmp_deeply $res->{status}, set('ASK_FIX_DETAILS'), 'correct status';
    cmp_deeply $res->{missing_fields}, ['address_city'], 'missing fields for withdrawal returned';

    $cr_client->address_city($address_city);
    $cr_client->save;

    $mock_client->mock(missing_requirements => 'first_name');
    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    cmp_deeply $res->{missing_fields}, ['first_name'], 'missing fields for deposit returned';
    $mock_client->unmock_all();

};

subtest 'Cashier validation deposit' => sub {
    $cr_client->status->set('unwelcome', 'system', 'pending investigations');

    my $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for unwelcome client';
    is $res->{error}->{message_to_client}, 'Your account is restricted to withdrawals only.', 'Correct error message for unwelcome client';
    cmp_deeply $res->{status}, set('unwelcome_status'), 'correct status';

    $cr_client->status->clear_unwelcome;

    $app_config->system->suspend->cryptocurrencies_deposit(['BTC']);
    $res = BOM::Platform::Client::CashierValidation::validate($cr_client_2->loginid, 'deposit');
    is $res->{error}{message_to_client}, 'Deposits are temporarily unavailable for BTC. Please try later.', 'crypto currency deposit suspended';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';
    $app_config->system->suspend->cryptocurrencies_deposit([]);

};

subtest 'Cashier validation withdraw' => sub {
    $cr_client->status->set('no_withdrawal_or_trading', 'system', 'pending investigations');

    my $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'withdraw');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for no_withdrawal_or_trading';
    is $res->{error}->{message_to_client}, 'Your account is restricted to deposits only.', 'Correct error message for no_withdrawal_or_trading';
    cmp_deeply $res->{status}, set('no_withdrawal_or_trading_status'), 'correct status';

    $cr_client->status->clear_no_withdrawal_or_trading;

    $cr_client->status->set('withdrawal_locked', 'system', 'pending investigations');

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'withdraw');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for withdrawal locked';
    is $res->{error}->{message_to_client}, 'Your account is locked for withdrawals.', 'Correct error message for withdrawal locked';
    cmp_deeply $res->{status}, set('withdrawal_locked_status'), 'correct status';

    $cr_client->status->clear_withdrawal_locked;

    $app_config->system->suspend->cryptocurrencies_withdrawal(['BTC']);
    $res = BOM::Platform::Client::CashierValidation::validate($cr_client_2->loginid, 'withdraw');
    is $res->{error}{message_to_client}, 'Withdrawals are temporarily unavailable for BTC. Please try later.', 'crypto currency withdrawal suspended';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';
    $app_config->system->suspend->cryptocurrencies_withdrawal([]);

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(is_financial_assessment_complete => 1);
    $cr_client_2->aml_risk_classification('high');
    $cr_client_2->save;
    $res = BOM::Platform::Client::CashierValidation::validate($cr_client_2->loginid, 'withdraw');

    cmp_deeply(
        $res,
        {
            error => {
                code              => 'ASK_AUTHENTICATE',
                message_to_client => 'Please authenticate your account.'
            },
            status => ['ASK_AUTHENTICATE']
        },
        'high risk client must be authenticated'
    );

    $cr_client_2->aml_risk_classification('low');
    $cr_client_2->save;
    $mock_client->unmock_all();
};

subtest 'Cashier validation landing company and country specific' => sub {
    subtest 'maltainvest' => sub {

        my $mock_client = Test::MockModule->new('BOM::User::Client');
        $mock_client->mock(is_financial_assessment_complete => 1);

        my $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
        is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';
        cmp_deeply $res->{status}, set('ASK_CURRENCY', 'ASK_AUTHENTICATE', 'ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'), 'correct status';

        $mf_client->set_default_account('EUR');
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_AUTHENTICATE',                  'Correct error code for not authenticated';
        is $res->{error}->{message_to_client}, 'Please authenticate your account.', 'Correct error message for not authenticated';
        cmp_deeply $res->{status}, set('ASK_AUTHENTICATE', 'ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'), 'correct status';

        $mock_client->mock(fully_authenticated => sub { note "mocked Client->fully_authenticated returning true"; 1 });

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_FINANCIAL_RISK_APPROVAL',          'Correct error code';
        is $res->{error}->{message_to_client}, 'Financial Risk approval is required.', 'Correct error message';
        cmp_deeply $res->{status}, set('ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'), 'correct status';

        $mf_client->status->set('financial_risk_approval', 'system', 'Accepted approval');

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_TIN_INFORMATION', 'Correct error code';
        is $res->{error}->{message_to_client},
            'Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
            'Correct error message';
        cmp_deeply $res->{status}, set('ASK_TIN_INFORMATION'), 'correct status';

        $mf_client->tax_residence($mf_client->residence);
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_TIN_INFORMATION',
            'Correct error code as tax identification number is also needed for database trigger to set status';
        cmp_deeply $res->{status}, set('ASK_TIN_INFORMATION'), 'correct status';

        $mf_client->tax_identification_number('111-222-333');
        $mf_client->save;

        # retail client can also deposit
        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res, undef, 'Validation passed for retail client';

        $mf_client->status->set("professional");

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res, undef, 'Validation passed for professional client';

        $mf_client->tax_residence(undef);
        $mf_client->tax_identification_number(undef);
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res, undef, 'Validation passed, making tax residence undef will not delete status';

        $mock_client->unmock('fully_authenticated');
    };

    subtest 'malta' => sub {
        $mlt_client->status->set('max_turnover_limit_not_set', 'system', '1');
        $mlt_client->set_default_account('EUR');
        $mlt_client->save;

        my $res = BOM::Platform::Client::CashierValidation::validate($mlt_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET', 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.',
            'Correct error message';
        cmp_deeply $res->{status}, set('ASK_SELF_EXCLUSION_MAX_TURNOVER_SET'), 'correct status';

        $mlt_client->status->clear_max_turnover_limit_not_set;

    };
    subtest 'gb as residence' => sub {
        my $res = BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
        is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';
        cmp_deeply $res->{status}, set('ASK_CURRENCY'), 'correct status';

        $mx_client->set_default_account('GBP');
        $mx_client->residence('gb');
        $mx_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_UK_FUNDS_PROTECTION',         'Correct error code';
        is $res->{error}->{message_to_client}, 'Please accept Funds Protection.', 'Correct error message';
        cmp_deeply $res->{status}, set('ASK_UK_FUNDS_PROTECTION'), 'correct status';

        $mx_client->status->set('ukgc_funds_protection',      'system', '1');
        $mx_client->status->set('max_turnover_limit_not_set', 'system', '1');

        $res = BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET', 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.',
            'Correct error message';
        cmp_deeply $res->{status}, set('ASK_SELF_EXCLUSION_MAX_TURNOVER_SET'), 'correct status';

        $mx_client->status->clear_max_turnover_limit_not_set;

        is BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit'), undef, 'Validation passed';
    };
};

subtest 'Calculate to amount and fees' => sub {
    my $mock_forex = Test::MockModule->new('BOM::Platform::Client::CashierValidation', no_auto => 1);
    my $mock_fees  = Test::MockModule->new('BOM::Config::CurrencyConfig',              no_auto => 1);
    $mock_fees->mock(
        transfer_between_accounts_fees => sub {
            return {
                'USD' => {
                    'UST' => 0.1,
                    'BTC' => 0.3,
                    'USD' => 0.5,    # ineffective (no fee should be charged for USD-USD)
                    'EUR' => 0.6
                },
                'UST' => {'USD' => 0.2},
                'BTC' => {
                    'USD' => 0.4,
                    'BTC' => 0.7     # ineffective (crypto-crypto transfer is not supported)
                }

            };
        });

    my $helper = sub {
        my (
            $amount_to_tranfer, $from_currency,           $to_currency,     $expected_fee_applied, $expected_fee_percent,
            $expected_fee_min,  $expected_fee_calculated, $mock_forex_rate, $from_cli,             $to_cli
        ) = @_;
        my $expected_amount = ($amount_to_tranfer - $expected_fee_applied) * $mock_forex_rate;

        $mock_forex->mock(convert_currency => sub { return (shift) * $mock_forex_rate; });
        my ($amount, $fee_applied, $fee_percent, $fee_min, $fee_calculated) =
            BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees($amount_to_tranfer, $from_currency, $to_currency,
            $from_cli, $to_cli);

        cmp_ok $amount,      '==', $expected_amount,      'Correct amount sent';
        cmp_ok $fee_applied, '==', $expected_fee_applied, 'Correct fee percent';
        cmp_ok $fee_percent, '==', $expected_fee_percent, 'Correct fee percent';
        cmp_ok $fee_min,     '==', $expected_fee_min,     'Correct fee percent';
        cmp_ok roundcommon(0.000001, $fee_calculated), '==', roundcommon(0.000001, $expected_fee_calculated), 'Correct fee percent';
    };

    subtest 'Fiat to stable crypto' => sub {
        $helper->(100, 'USD', 'UST', 0.1, 0.1, get_min_unit('USD'), 0.1, 1, $cr_client, $cr_client_2);
    };

    subtest 'Stable coin to fiat' => sub {
        $helper->(100, 'UST', 'USD', 0.2, 0.2, get_min_unit('UST'), 0.2, 1, $cr_client, $cr_client_2);
    };

    subtest 'Minimum fee enforcement (lower than threshold)' => sub {
        $helper->(1, 'UST', 'USD', get_min_unit('UST'), 0.2, get_min_unit('UST'), 0.002, 1);
    };

    subtest 'Minimum fee enforcement 2 (lower than threshold)' => sub {
        $helper->(1.04, 'USD', 'UST', get_min_unit('USD'), 0.1, get_min_unit('USD'), 0.00104, 1);
    };

    subtest 'Fiat to crypto' => sub {
        $helper->(100, 'USD', 'BTC', 0.3, 0.3, get_min_unit('USD'), 0.3, 7000, $cr_client, $cr_client_2);

        throws_ok {
            $helper->(0.01, 'USD', 'BTC', 0.3, 0.3, get_min_unit('USD'), 0.3, 7000, $cr_client, $cr_client_2);
        }
        qr/The amount \(0\) is below the minimum allowed amount \(0.00000001\) for BTC/, 'Too low amount for receiving account fails.';

    };

    subtest 'Crypto to fiat' => sub {
        $helper->(100, 'BTC', 'USD', 0.4, 0.4, get_min_unit('BTC'), 0.4, 1 / 7000, $cr_client, $cr_client_2);
    };

    subtest 'MF (USD) to MLT (USD)' => sub {
        $helper->(100, 'USD', 'USD', 0, 0, 0, 0, 1, $mf_client, $mlt_client);
    };

    subtest 'MLT (USD) to MF (USD)' => sub {
        $helper->(100, 'USD', 'USD', 0, 0, 0, 0, 1, $mlt_client, $mf_client);
    };

    subtest 'Fiat to fiat (for MT5 deposit/withdrawal)' => sub {
        $helper->(100, 'USD', 'EUR', 0.6, 0.6, get_min_unit('USD'), 0.6, 1.1);
    };

    subtest 'PA fee exemption #1 (clients under same user, sender is PA)' => sub {
        my $mock_client = Test::MockModule->new('BOM::User::Client');
        $mock_client->mock(is_pa_and_authenticated => sub { return 1 if (shift)->loginid eq $cr_client->loginid; });
        $helper->(100, 'USD', 'BTC', 0, 0, 0, 0, 7000, $cr_client, $cr_client_2);
        $mock_client->unmock('is_pa_and_authenticated');
    };

    subtest 'PA fee exemption #2 (clients under same user, receiever is PA)' => sub {
        my $mock_client = Test::MockModule->new('BOM::User::Client');
        $mock_client->mock(is_pa_and_authenticated => sub { return 1 if (shift)->loginid eq $cr_client_2->loginid; });
        $helper->(100, 'BTC', 'USD', 0, 0, 0, 0, 1 / 7000, $cr_client, $cr_client_2);
        $mock_client->unmock('is_pa_and_authenticated');
    };

    subtest 'PA fee exemption #3 (clients under same user, both are PA)' => sub {
        my $mock_client = Test::MockModule->new('BOM::User::Client');
        $mock_client->mock(is_pa_and_authenticated => sub { return 1; });
        $helper->(100, 'USD', 'BTC', 0, 0, 0, 0, 7000, $cr_client, $cr_client_2);
        $mock_client->unmock('is_pa_and_authenticated');
    };

    subtest 'Crypto to crypto' => sub {
        throws_ok {
            $helper->(100, 'BTC', 'ETH', 0, 0, 0, 0, 12, $cr_client, $cr_client_2);
        }
        qr/No transfer fee found for BTC-ETH/, 'Crypto to crypto dies';
    };

    $mock_forex->unmock('convert_currency');
    $mock_fees->unmock('transfer_between_accounts_fees');
};

done_testing();
