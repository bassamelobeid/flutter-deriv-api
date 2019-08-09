use strict;
use warnings;

use Date::Utility;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Warnings;

use ExchangeRates::CurrencyConverter;
use Format::Util::Numbers qw/get_min_unit roundcommon/;

use BOM::User::Client;
use BOM::Config::Runtime;
use BOM::Platform::Client::CashierValidation;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my ($generic_err_code, $new_email, $vr_client, $cr_client, $cr_client_2, $cr_client_jpy, $mlt_client, $mf_client, $mx_client) =
    ('CashierForwardError');

subtest prepare => sub {
    $new_email = 'test' . rand . '@binary.com';
    $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $new_email,
    });

    $new_email = 'test' . rand . '@binary.com';
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

    pass "Prepration successful";
};

subtest 'Check cashier suspended' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->payments(1);
    my $res = BOM::Platform::Client::CashierValidation::validate($vr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, cashier is temporarily unavailable due to system maintenance.', 'Correct error message';
    BOM::Config::Runtime->instance->app_config->system->suspend->payments(0);

    BOM::Config::Runtime->instance->app_config->system->suspend->cryptocashier(1);
    ok BOM::Platform::Client::CashierValidation::is_crypto_cashier_suspended, 'crpto cashier suspended';
    BOM::Config::Runtime->instance->app_config->system->suspend->cryptocashier(0);
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
    $cr_client->status->set('cashier_locked', 'system', 'pending investigations');
    $cr_client->save();

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code if client is cashier locked';
    is $res->{error}->{message_to_client}, 'Your cashier is locked.', 'Correct error message if client is cashier locked';

    $cr_client->status->clear_cashier_locked;
    $cr_client->status->set('disabled', 'system', 'pending investigations');

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code as its disabled';
    is $res->{error}->{message_to_client}, 'Your account is disabled.', 'Correct error message as its disabled';

    $cr_client->status->clear_disabled;
    $cr_client->cashier_setting_password('abc123');
    $cr_client->save();

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for cashier locked';
    is $res->{error}->{message_to_client}, 'Your cashier is locked as per your request.', 'Correct error message for cashier locked';

    $cr_client->cashier_setting_password('');
    $cr_client->save();

    ok !$cr_client->documents_expired, "No documents so nothing to expire";
    my ($doc) = $cr_client->add_client_authentication_document({
        document_type              => "passport",
        document_format            => "PDF",
        document_path              => '/tmp/test.pdf',
        expiration_date            => '2008-03-03',
        authentication_method_code => 'ID_DOCUMENT',
        status                     => 'uploaded',
        checksum                   => 'CE114E4501D2F4E2DCEA3E17B546F339'
    });
    $cr_client->save;

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for expired documents';
    is $res->{error}->{message_to_client},
        'Your identity documents have passed their expiration date. Kindly send a scan of a valid identity document to support@binary.com to unlock your cashier.',
        'Correct error message for expired documents';

    my $new_expiration_date = Date::Utility->new()->plus_time_interval('1d')->date;
    $cr_client->client_authentication_document->[0]->expiration_date($new_expiration_date);
    $cr_client->save;
};

subtest 'Cashier validation deposit' => sub {
    $cr_client->status->set('unwelcome', 'system', 'pending investigations');

    my $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'deposit');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for unwelcome client';
    is $res->{error}->{message_to_client}, 'Your account is restricted to withdrawals only.', 'Correct error message for unwelcome client';

    $cr_client->status->clear_unwelcome;
};

subtest 'Cashier validation withdraw' => sub {
    $cr_client->status->set('no_withdrawal_or_trading', 'system', 'pending investigations');

    my $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'withdraw');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for to_be_decided';
    is $res->{error}->{message_to_client}, 'Your account is restricted to deposits only.', 'Correct error message for to_be_decided';

    $cr_client->status->clear_no_withdrawal_or_trading;

    $cr_client->status->set('withdrawal_locked', 'system', 'pending investigations');

    $res = BOM::Platform::Client::CashierValidation::validate($cr_client->loginid, 'withdraw');
    is $res->{error}->{code}, $generic_err_code, 'Correct error code for withdrawal locked';
    is $res->{error}->{message_to_client}, 'Your account is locked for withdrawals.', 'Correct error message for withdrawal locked';

    $cr_client->status->clear_withdrawal_locked;
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

        my $mock_client = Test::MockModule->new('BOM::User::Client');
        $mock_client->mock(fully_authenticated => sub { note "mocked Client->fully_authenticated returning true"; 1 });

        $res = BOM::Platform::Client::CashierValidation::validate($mf_client->loginid, 'deposit');
        is $res->{error}->{code},              'ASK_FINANCIAL_RISK_APPROVAL',          'Correct error code';
        is $res->{error}->{message_to_client}, 'Financial Risk approval is required.', 'Correct error message';

        $mf_client->status->set('financial_risk_approval', 'system', 'Accepted approval');

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

        $mlt_client->status->clear_max_turnover_limit_not_set;

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

        $mx_client->status->set('ukgc_funds_protection',      'system', '1');
        $mx_client->status->set('max_turnover_limit_not_set', 'system', '1');

        $res = BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit');
        is $res->{error}->{code}, 'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET', 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.',
            'Correct error message';

        $mx_client->status->clear_max_turnover_limit_not_set;

        is BOM::Platform::Client::CashierValidation::validate($mx_client->loginid, 'deposit'), undef, 'Validation passed';
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

        $mlt_client->status->set('age_verification', 'system', 1);

        $res = BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mlt_client->loginid, 2000);
        is $res->{error}->{code}, $generic_err_code, 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please authenticate your account.', 'Correct error message';
        is BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mlt_client->loginid, 1999), undef,
            'Amount less than allowed limit hence validation passed';

        $res = BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mx_client->loginid, 1000);
        is $res->{error}->{code}, $generic_err_code, 'Correct error code';
        is $res->{error}->{message_to_client}, 'Account needs age verification.', 'Correct error message';

        $mx_client->status->set('age_verification', 'system', 1);

        $res = BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mx_client->loginid, 3000);
        is $res->{error}->{code}, $generic_err_code, 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please authenticate your account.', 'Correct error message';

        is BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($cr_client->loginid, 10000), undef,
            'Not applicable for CR hence validation passed';

        my $mock_client = Test::MockModule->new('BOM::User::Client');
        $mock_client->mock(fully_authenticated => sub { note "mocked Client->fully_authenticated returning true"; 1 });

        is BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mlt_client->loginid, 10000), undef,
            'Fully authenticated and age verified hence passed';
        is BOM::Platform::Client::CashierValidation::pre_withdrawal_validation($mx_client->loginid, 10000), undef,
            'Fully authenticated and age verified hence passed';

        $mock_client->unmock('fully_authenticated');
    };
};

subtest 'Calculate to amount and fees' => sub {
    my $mock_forex = Test::MockModule->new('BOM::Platform::Client::CashierValidation', no_auto => 1);
    my $mock_fees = Test::MockModule->new('BOM::Config::CurrencyConfig', no_auto => 1);
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
            $helper->(100, 'BTC', 'BCH', 0, 0, 0, 0, 12, $cr_client, $cr_client_2);
        }
        qr/No transfer fee found for BTC-BCH/, 'Crypto to crypto dies';
    };

    $mock_forex->unmock('convert_currency');
    $mock_fees->unmock('transfer_between_accounts_fees');
};

done_testing();
