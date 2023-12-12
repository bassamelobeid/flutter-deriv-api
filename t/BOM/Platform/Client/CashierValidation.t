use strict;
use warnings;

use Date::Utility;
use Test::More;
use Test::Exception;
use Test::Fatal;
use Test::MockModule;
use Test::MockObject;
use Test::Warnings;
use Test::Deep;

use ExchangeRates::CurrencyConverter;
use Format::Util::Numbers qw/get_min_unit roundcommon/;
use List::Util;

use BOM::User::Client;
use BOM::Config::CurrencyConfig;
use BOM::Config::Runtime;
use BOM::Platform::Client::CashierValidation;
use BOM::Rules::Engine;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Utility                     qw(error_map);
use BOM::Platform::Context                     qw(localize);

my ($generic_err_code, $new_email, $vr_client, $cr_client, $cr_client_2, $mlt_client, $mf_client, $mx_client, $rule_engine) = ('CashierForwardError');

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

    $rule_engine = BOM::Rules::Engine->new(
        stop_on_failure => 0,
        client          => [$vr_client, $cr_client, $cr_client_2, $mlt_client, $mf_client, $mx_client]);

    pass "Prepration successful";
};

subtest 'basic tests' => sub {
    my %args = (
        loginid     => $vr_client->loginid,
        action      => 'withdraw',
        amount      => 0,
        rule_engine => $rule_engine
    );
    my $res = BOM::Platform::Client::CashierValidation::validate(%args);
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'This is a virtual-money account. Please switch to a real-money account to access cashier.',
        'Correct error message';
    is $res->{status}, undef, 'no status';

    $args{loginid} = $cr_client->loginid;
    $args{action}  = 'deposit';
    $res           = BOM::Platform::Client::CashierValidation::validate(%args);
    is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
    is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';
    cmp_deeply $res->{status}, ['ASK_CURRENCY'], 'correct status';

    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => 'CR1223321');
    is $res->{error}->{code},              $generic_err_code,  'Correct error code for invalid loginid';
    is $res->{error}->{message_to_client}, 'Invalid account.', 'Correct error message for invalid loginid';
    cmp_deeply $res->{status}, undef, 'correct status';
};

subtest 'System suspend' => sub {
    $cr_client->set_default_account('USD');
    $cr_client_2->set_default_account('BTC');

    my %args = (
        loginid     => $cr_client->loginid,
        action      => 'deposit',
        amount      => 0,
        rule_engine => $rule_engine
    );

    $app_config->system->suspend->payments(1);
    my $res = BOM::Platform::Client::CashierValidation::validate(%args);
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Payments suspended error for fiat client';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';

    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => $cr_client_2->loginid);
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Payments suspended error for crypto client';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';

    $app_config->system->suspend->payments(0);

    $app_config->system->suspend->cashier(1);

    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => $cr_client->loginid);
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, cashier is temporarily unavailable due to system maintenance.',
        'Cashier suspended error for fiat client';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';

    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => $cr_client_2->loginid);
    unlike $res->{error}->{message_to_client} // '', '/cashier is temporarily unavailable/', 'crypto client is unaffected';

    $app_config->system->suspend->cashier(0);

    $app_config->system->suspend->cryptocashier(1);

    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => $cr_client_2->loginid);
    is $res->{error}->{code}, $generic_err_code, 'Correct error code';
    is $res->{error}->{message_to_client}, 'Sorry, crypto cashier is temporarily unavailable due to system maintenance.',
        'Cashier suspended error for crypto client';
    cmp_deeply $res->{status}, set('system_maintenance'), 'correct status';

    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => $cr_client->loginid);
    unlike $res->{error}->{message_to_client} // '', '/cashier is temporarily unavailable/', 'fiat client is unaffected';

    $app_config->system->suspend->cryptocashier(0);

    $app_config->system->suspend->cryptocurrencies('BTC');
    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => $cr_client_2->loginid);
    is $res->{error}{message_to_client}, 'Sorry, crypto cashier is temporarily unavailable due to system maintenance.', 'Crypto currency suspended';
    $app_config->system->suspend->cryptocurrencies('');
};

subtest 'Cashier validation common' => sub {

    my $country = $cr_client->residence;
    $cr_client->residence('');
    $cr_client->save();

    my %args = (
        loginid     => $cr_client->loginid,
        action      => 'withdraw',
        amount      => 0,
        rule_engine => $rule_engine
    );

    my $res = BOM::Platform::Client::CashierValidation::validate(%args);
    is $res->{error}->{code},              $generic_err_code,                       'Correct error code for no residence';
    is $res->{error}->{message_to_client}, 'Please set your country of residence.', 'Correct error message for no residence';
    cmp_deeply $res->{status}, set('no_residence'), 'correct status';

    $cr_client->residence($country);

    $cr_client->status->set('cashier_locked', 'system', 'pending investigations');
    $cr_client->save();
    $res = BOM::Platform::Client::CashierValidation::validate(%args, action => 'deposit');
    is $res->{error}->{code},              $generic_err_code,         'Correct error code if client is cashier locked';
    is $res->{error}->{message_to_client}, 'Your cashier is locked.', 'Correct error message if client is cashier locked';
    cmp_deeply $res->{status}, set('cashier_locked_status'), 'correct status';

    $cr_client->status->clear_cashier_locked;
    $cr_client->status->set('disabled', 'system', 'pending investigations');

    $res = BOM::Platform::Client::CashierValidation::validate(%args, action => 'deposit');
    is $res->{error}->{code},              $generic_err_code,           'Correct error code as its disabled';
    is $res->{error}->{message_to_client}, 'Your account is disabled.', 'Correct error message as its disabled';
    cmp_deeply $res->{status}, set('disabled_status'), 'correct status';

    $cr_client->status->clear_disabled;

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(is_financial_assessment_complete => 0);

    $res = BOM::Platform::Client::CashierValidation::validate(%args, action => 'deposit');
    ok !$res, 'No error due to not completed financial assessment for deposit correctly';

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
    $cr_client->{documents} = undef;    # force it to reload documents

    $res = BOM::Platform::Client::CashierValidation::validate(%args, action => 'deposit');
    is $res->{error}->{code}, undef, 'Correct error code for expired documents but expired check not required';

    $mock_client->mock(is_document_expiry_check_required => sub { note "mocked Client->is_document_expiry_check_required returning true"; 1 });

    $res = BOM::Platform::Client::CashierValidation::validate(%args, action => 'deposit');
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
        code              => 'ASK_FIX_DETAILS',
        details           => {'fields' => ['address_city']},
        params            => [],
        message_to_client => 'Your profile appears to be incomplete. Please update your personal details to continue.'
    };

    $res = BOM::Platform::Client::CashierValidation::validate(%args, action => 'withdraw');
    is_deeply($res->{error}, $expected, 'lc withdrawal requirements validated');
    cmp_deeply $res->{status},         set('ASK_FIX_DETAILS'), 'correct status';
    cmp_deeply $res->{missing_fields}, ['address_city'],       'missing fields for withdrawal returned';

    $cr_client->address_city($address_city);
    $cr_client->save;

    $mock_client->mock(missing_requirements => 'first_name');
    $res = BOM::Platform::Client::CashierValidation::validate(%args, action => 'deposit');
    cmp_deeply $res->{missing_fields}, ['first_name'], 'missing fields for deposit returned', 0, $rule_engine;
    $mock_client->unmock_all();

    my $excluded_until = '2000-01-01';
    $mock_client->redefine('get_self_exclusion_until_date' => $excluded_until);
    $res = BOM::Platform::Client::CashierValidation::validate(%args, action => 'deposit');

    cmp_deeply(
        $res,
        {
            error => {
                code              => 'SelfExclusion',
                params            => [$excluded_until],
                details           => {excluded_until => $excluded_until},
                message_to_client =>
                    "You have chosen to exclude yourself from trading on our website until $excluded_until. If you are unable to place a trade or deposit after your self-exclusion period, please contact us via live chat.",
            },
            status => ['SelfExclusion'],
        },
        'correct response for self excluded until date',
    );

    $mock_client->unmock_all();
};

subtest 'Cashier validation deposit' => sub {
    my %args = (
        loginid     => $cr_client->loginid,
        action      => 'deposit',
        amount      => 0,
        rule_engine => $rule_engine
    );

    $cr_client->status->set('unwelcome', 'system', 'pending investigations');

    my $res = BOM::Platform::Client::CashierValidation::validate(%args);
    is $res->{error}->{code},              $generic_err_code,                                 'Correct error code for unwelcome client';
    is $res->{error}->{message_to_client}, 'Your account is restricted to withdrawals only.', 'Correct error message for unwelcome client';
    cmp_deeply $res->{status}, set('unwelcome_status'), 'correct status';

    $cr_client->status->clear_unwelcome;

    $app_config->system->suspend->cryptocurrencies_deposit(['BTC']);
    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => $cr_client_2->loginid);
    is $res->{error}{message_to_client}, 'Deposits are temporarily unavailable for BTC. Please try later.', 'crypto currency deposit suspended';
    cmp_deeply $res->{status}, set('system_maintenance_deposit_outage'), 'correct status';
    $app_config->system->suspend->cryptocurrencies_deposit([]);

};

subtest 'Cashier validation withdraw' => sub {
    my %args = (
        loginid     => $cr_client->loginid,
        action      => 'withdraw',
        amount      => 0,
        rule_engine => $rule_engine
    );

    $cr_client->status->set('no_withdrawal_or_trading', 'system', 'pending investigations');

    my $res = BOM::Platform::Client::CashierValidation::validate(%args);
    is $res->{error}->{code},              $generic_err_code,                              'Correct error code for no_withdrawal_or_trading';
    is $res->{error}->{message_to_client}, 'Your account is restricted to deposits only.', 'Correct error message for no_withdrawal_or_trading';
    cmp_deeply $res->{status}, set('no_withdrawal_or_trading_status'), 'correct status';

    $cr_client->status->clear_no_withdrawal_or_trading;

    $cr_client->status->set('withdrawal_locked', 'system', 'pending investigations');

    $res = BOM::Platform::Client::CashierValidation::validate(%args);
    is $res->{error}->{code},              $generic_err_code,                         'Correct error code for withdrawal locked';
    is $res->{error}->{message_to_client}, 'Your account is locked for withdrawals.', 'Correct error message for withdrawal locked';
    cmp_deeply $res->{status}, set('withdrawal_locked_status'), 'correct status';

    $cr_client->status->clear_withdrawal_locked;

    $app_config->system->suspend->cryptocurrencies_withdrawal(['BTC']);
    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => $cr_client_2->loginid);
    is $res->{error}{message_to_client}, 'Withdrawals are temporarily unavailable for BTC. Please try later.', 'crypto currency withdrawal suspended';
    cmp_deeply $res->{status}, set('system_maintenance_withdrawal_outage'), 'correct status';
    $app_config->system->suspend->cryptocurrencies_withdrawal([]);

    my $mock_client = Test::MockModule->new('BOM::User::Client');
    $mock_client->mock(is_financial_assessment_complete => 1);
    $cr_client_2->aml_risk_classification('high');
    $cr_client_2->save;
    $res = BOM::Platform::Client::CashierValidation::validate(%args, loginid => $cr_client_2->loginid);

    cmp_deeply(
        $res,
        {
            error => {
                code              => 'ASK_AUTHENTICATE',
                params            => [],
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

        my %args = (
            loginid     => $mf_client->loginid,
            action      => 'deposit',
            amount      => 0,
            rule_engine => $rule_engine
        );

        my $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
        is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';
        cmp_deeply $res->{status}, set('ASK_CURRENCY', 'ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'), 'correct status';

        $mf_client->set_default_account('EUR');
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code}, 'ASK_FINANCIAL_RISK_APPROVAL', 'Correct error code for incomplete financial approval';
        is $res->{error}->{message_to_client}, 'Financial Risk approval is required.',
            'Correct error message for financial approval is not completed';
        cmp_deeply $res->{status}, set('ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'), 'correct status';
        $mock_client->mock(has_deposits => sub { note "mocked Client->has_deposits returning true"; 1 });

        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code},              'ASK_AUTHENTICATE',                  'Correct error code for unauthentication is received';
        is $res->{error}->{message_to_client}, 'Please authenticate your account.', 'Correct error message for unathentication is received';
        cmp_deeply $res->{status}, set('ASK_AUTHENTICATE', 'ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'), 'correct status';

        $mock_client->mock(fully_authenticated => sub { note "mocked Client->fully_authenticated returning true"; 1 });

        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code},              'ASK_FINANCIAL_RISK_APPROVAL',          'Correct error code';
        is $res->{error}->{message_to_client}, 'Financial Risk approval is required.', 'Correct error message';
        cmp_deeply $res->{status}, set('ASK_FINANCIAL_RISK_APPROVAL', 'ASK_TIN_INFORMATION'), 'correct status';

        $mf_client->status->set('financial_risk_approval', 'system', 'Accepted approval');

        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code}, 'ASK_TIN_INFORMATION', 'Correct error code';
        is $res->{error}->{message_to_client},
            'Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
            'Correct error message';
        cmp_deeply $res->{status}, set('ASK_TIN_INFORMATION'), 'correct status';

        $mf_client->tax_residence($mf_client->residence);
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code}, 'ASK_TIN_INFORMATION',
            'Correct error code as tax identification number is also needed for database trigger to set status';
        cmp_deeply $res->{status}, set('ASK_TIN_INFORMATION'), 'correct status';

        $mf_client->tax_identification_number('111-222-333');
        $mf_client->save;
        $mf_client->{status} = undef;    #force it to reload

        # retail client can also deposit
        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res, undef, 'Validation passed for retail client';

        $mf_client->status->set("professional");

        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res, undef, 'Validation passed for professional client';

        $mf_client->tax_residence(undef);
        $mf_client->tax_identification_number(undef);
        $mf_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res, undef, 'Validation passed, making tax residence undef will not delete status';

        my $mf_residence = $mf_client->residence;
        $mf_client->residence('gb');
        $mf_client->save;
        is BOM::Platform::Client::CashierValidation::validate(%args), undef, 'UK MF client does not need ukgc_funds_protection';
        $mf_client->residence($mf_residence);
        $mf_client->save;

        $mock_client->unmock('fully_authenticated');
    };

    subtest 'malta' => sub {
        $mlt_client->status->set('max_turnover_limit_not_set', 'system', '1');
        $mlt_client->set_default_account('EUR');
        $mlt_client->save;

        my %args = (
            loginid     => $mlt_client->loginid,
            action      => 'deposit',
            amount      => 0,
            rule_engine => $rule_engine
        );
        my $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code}, 'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET', 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.',
            'Correct error message';
        cmp_deeply $res->{status}, set('ASK_SELF_EXCLUSION_MAX_TURNOVER_SET'), 'correct status';

        $mlt_client->status->clear_max_turnover_limit_not_set;

    };
    subtest 'gb as residence' => sub {
        my %args = (
            loginid     => $mx_client->loginid,
            action      => 'deposit',
            amount      => 0,
            rule_engine => $rule_engine
        );

        my $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code},              'ASK_CURRENCY',             'Correct error code for account currency not set';
        is $res->{error}->{message_to_client}, 'Please set the currency.', 'Correct error message for account currency not set';
        cmp_deeply $res->{status}, set('ASK_CURRENCY'), 'correct status';

        $mx_client->set_default_account('GBP');
        $mx_client->residence('gb');
        $mx_client->save;

        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code},              'ASK_UK_FUNDS_PROTECTION',         'Correct error code';
        is $res->{error}->{message_to_client}, 'Please accept Funds Protection.', 'Correct error message';
        cmp_deeply $res->{status}, set('ASK_UK_FUNDS_PROTECTION'), 'correct status';

        $mx_client->status->set('ukgc_funds_protection',      'system', '1');
        $mx_client->status->set('max_turnover_limit_not_set', 'system', '1');

        $res = BOM::Platform::Client::CashierValidation::validate(%args);
        is $res->{error}->{code}, 'ASK_SELF_EXCLUSION_MAX_TURNOVER_SET', 'Correct error code';
        is $res->{error}->{message_to_client}, 'Please set your 30-day turnover limit in our self-exclusion facilities to access the cashier.',
            'Correct error message';
        cmp_deeply $res->{status}, set('ASK_SELF_EXCLUSION_MAX_TURNOVER_SET'), 'correct status';

        $mx_client->status->clear_max_turnover_limit_not_set;

        is BOM::Platform::Client::CashierValidation::validate(%args), undef, 'Validation passed';
    };
};

subtest 'Calculate to amount and fees' => sub {
    my $mock_forex  = Test::MockModule->new('BOM::Platform::Client::CashierValidation', no_auto => 1);
    my $mock_fees   = Test::MockModule->new('BOM::Config::CurrencyConfig',              no_auto => 1);
    my $mock_client = Test::MockModule->new('BOM::User::Client',                        no_auto => 1);
    my $fees_country;

    $mock_fees->mock(
        transfer_between_accounts_fees => sub {
            $fees_country = shift;
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

    my @tests = ({
            name => 'Fiat to stable crypto',
            args => {
                amount        => 100,
                from_currency => 'USD',
                to_currency   => 'UST',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate      => 1,
            fee_applied    => 0.1,
            fee_percent    => 0.1,
            fee_min        => get_min_unit('USD'),
            fee_calculated => 0.1,
        },
        {
            name => 'Stable coin to fiat',
            args => {
                amount        => 100,
                from_currency => 'UST',
                to_currency   => 'USD',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate      => 1,
            fee_applied    => 0.2,
            fee_percent    => 0.2,
            fee_min        => get_min_unit('UST'),
            fee_calculated => 0.2,
        },
        {
            name => 'Minimum fee enforcement (lower than threshold)',
            args => {
                amount        => 1,
                from_currency => 'UST',
                to_currency   => 'USD',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate      => 1,
            fee_applied    => get_min_unit('UST'),
            fee_percent    => 0.2,
            fee_min        => get_min_unit('UST'),
            fee_calculated => 0.002,
        },
        {
            name => 'Minimum fee enforcement 2 (lower than threshold)',
            args => {
                amount        => 1.04,
                from_currency => 'USD',
                to_currency   => 'UST',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate      => 1,
            fee_applied    => get_min_unit('USD'),
            fee_percent    => 0.1,
            fee_min        => get_min_unit('USD'),
            fee_calculated => 0.00104,
        },
        {
            name => 'Fiat to crypto',
            args => {
                amount        => 100,
                from_currency => 'USD',
                to_currency   => 'BTC',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate      => 7000,
            fee_applied    => 0.3,
            fee_percent    => 0.3,
            fee_min        => get_min_unit('USD'),
            fee_calculated => 0.3,
        },
        {
            name => 'Fiat to crypto - converted amount below minimum',
            args => {
                amount        => 0.01,
                from_currency => 'USD',
                to_currency   => 'BTC',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate => 7000,
            error     => 'The amount \(0\) is below the minimum allowed amount \(0.00000001\) for BTC',
        },
        {
            name => 'Crypto to fiat',
            args => {
                amount        => 100,
                from_currency => 'BTC',
                to_currency   => 'USD',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate      => 1 / 7000,
            fee_applied    => 0.4,
            fee_percent    => 0.4,
            fee_min        => get_min_unit('BTC'),
            fee_calculated => 0.4,
        },
        {
            name => 'MF (USD) to MLT (USD)',
            args => {
                amount        => 100,
                from_currency => 'USD',
                to_currency   => 'USD',
                from_client   => $mf_client,
                to_client     => $mlt_client,
            },
            mock_rate      => 1,
            fee_applied    => 0,
            fee_percent    => 0,
            fee_min        => 0,
            fee_calculated => 0,
        },
        {
            name => 'MF (USD) to MLT (USD)',
            args => {
                amount        => 100,
                from_currency => 'USD',
                to_currency   => 'USD',
                from_client   => $mlt_client,
                to_client     => $mf_client,
            },
            mock_rate      => 1,
            fee_applied    => 0,
            fee_percent    => 0,
            fee_min        => 0,
            fee_calculated => 0,
        },
        {
            name => 'Fiat to fiat (for MT5 deposit/withdrawal)',
            args => {
                amount        => 100,
                from_currency => 'USD',
                to_currency   => 'EUR',
                country       => 'za',
            },
            mock_rate      => 1.1,
            fee_applied    => 0.6,
            fee_percent    => 0.6,
            fee_min        => get_min_unit('USD'),
            fee_calculated => 0.6,
        },
        {
            name => 'PA fee exemption #1 (clients under same user, sender is PA)',
            args => {
                amount        => 100,
                from_currency => 'USD',
                to_currency   => 'BTC',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate      => 7000,
            fee_applied    => 0,
            fee_percent    => 0,
            fee_min        => 0,
            fee_calculated => 0,
            auth_loginids  => [$cr_client->loginid]
        },
        {
            name => 'PA fee exemption #2 (clients under same user, receiever is PA',
            args => {
                amount        => 100,
                from_currency => 'BTC',
                to_currency   => 'USD',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate      => 1 / 7000,
            fee_applied    => 0,
            fee_percent    => 0,
            fee_min        => 0,
            fee_calculated => 0,
            auth_loginids  => [$cr_client_2->loginid]
        },
        {
            name => 'PA fee exemption #3 (clients under same user, both are PA',
            args => {
                amount        => 100,
                from_currency => 'USD',
                to_currency   => 'BTC',
                from_client   => $cr_client,
                to_client     => $cr_client_2,
            },
            mock_rate      => 7000,
            fee_applied    => 0,
            fee_percent    => 0,
            fee_min        => 0,
            fee_calculated => 0,
            auth_loginids  => [$cr_client->loginid, $cr_client_2->loginid]
        },
        {
            name => 'No fee',
            args => {
                amount        => 100,
                from_currency => 'BTC',
                to_currency   => 'ETH',
            },
            mock_rate => 1,
            error     => 'No transfer fee found for BTC-ETH',
        },
    );

    my $mock_rate;
    $mock_forex->mock(convert_currency => sub { (shift) * $mock_rate });

    my @auth_loginids;
    $mock_client->mock(
        is_pa_and_authenticated => sub {
            my $self = shift;
            List::Util::any { $self->loginid eq $_ } @auth_loginids;
        });

    for my $test (@tests) {
        subtest $test->{name} => sub {
            $mock_rate     = $test->{mock_rate};
            @auth_loginids = ($test->{auth_loginids} // [])->@*;
            $fees_country  = undef;

            my $err = exception {
                my ($amount, $fee_applied, $fee_percent, $fee_min, $fee_calculated) =
                    BOM::Platform::Client::CashierValidation::calculate_to_amount_with_fees($test->{args}->%*);

                my $expected_amount = ($test->{args}{amount} - $test->{fee_applied}) * $mock_rate;
                cmp_ok $amount,                                '==', $expected_amount,                               'Correct amount sent';
                cmp_ok $fee_applied,                           '==', $test->{fee_applied},                           'Correct fee percent';
                cmp_ok $fee_percent,                           '==', $test->{fee_percent},                           'Correct fee percent';
                cmp_ok $fee_min,                               '==', $test->{fee_min},                               'Correct fee percent';
                cmp_ok roundcommon(0.000001, $fee_calculated), '==', roundcommon(0.000001, $test->{fee_calculated}), 'Correct calculated fee';
                is $fees_country, $test->{args}{country}, 'country passed to transfer_between_accounts_fees()';
            };

            $test->{error} //= 'none';
            like $err // 'none', qr/$test->{error}/, 'got expected error: ' . $test->{error};
        };
    }
};

subtest 'uderlying action' => sub {
    $cr_client_2->payment_agent({
        payment_agent_name    => 'Joe',
        email                 => 'joe@example.com',
        information           => 'Test Info',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        status                => 'authorized',
        currency_code         => 'USD',
        is_listed             => 't',
    });
    $cr_client_2->save;

    my $pa = $cr_client_2->get_payment_agent;

    my %args = (
        loginid     => $cr_client_2->loginid,
        action      => 'withdraw',
        amount      => 0,
        rule_engine => $rule_engine
    );

    my $expected_error = {
        message_to_client => 'This service is not available for payment agents.',
        code              => 'CashierForwardError',
        params            => [],
    };

    my $mock_pa      = Test::MockModule->new('BOM::User::Client::PaymentAgent');
    my $tier_details = {};
    $mock_pa->redefine(tier_details => sub { $tier_details });

    my $res = BOM::Platform::Client::CashierValidation::validate(%args);
    is_deeply $res->{error}, $expected_error, 'Cashier validation fails for withdrawal by a PA by default';

    for my $action_name (qw(withdraw payment_withdraw cashier_withdraw)) {
        $tier_details->{cashier_withdraw} = 0;
        $res = BOM::Platform::Client::CashierValidation::validate(%args, underlying_action => $action_name);
        is_deeply $res->{error}, $expected_error, "Cashier validation fails for withdrawal by a PA with underlying action = $action_name";

        $tier_details->{cashier_withdraw} = 1;
        $res = BOM::Platform::Client::CashierValidation::validate(%args, underlying_action => $action_name);
        is $res->{error}, undef, "Cashier validation passes for action $action_name if the service is allowed for the PA";
    }

    $res = BOM::Platform::Client::CashierValidation::validate(%args, underlying_action => 'dummy');
    is $res, undef, 'Cashier validation passes for withdrawal by a PA with a dummy underlying action';
};

subtest 'validate_payment_error' => sub {

    my $currency = 'BTC';
    $cr_client_2->set_default_account($currency);

    sub _cmp_deeply_validate_payment_error {
        my ($error_code, $args, $test_name) = @_;

        $args //= [];

        cmp_deeply BOM::Platform::Client::CashierValidation::validate_payment_error($cr_client_2, $args->[0]),
            $error_code
            ? {
            error => {
                code              => $error_code,
                message_to_client => localize(error_map()->{$error_code}, $args->@*),
            }}
            : undef,
            $test_name;
    }

    my $mocked_client = Test::MockModule->new('BOM::User::Client');
    my $client_error;
    $mocked_client->mock(validate_payment => sub { die $client_error });

    my ($amount, $limit) = (0.5, 0.1);
    my $params = [$amount, $currency, $limit];

    $client_error = {
        code   => 'WithdrawalLimit',
        params => [$limit, $currency],
    };
    _cmp_deeply_validate_payment_error('CryptoWithdrawalLimitExceeded', $params, 'Returns error when withdrawal amount exceeds withdrawal limit.');

    $client_error = {
        code   => 'AmountExceedsBalance',
        params => [$amount, $currency, $limit],
    };
    _cmp_deeply_validate_payment_error('CryptoWithdrawalBalanceExceeded', $params, 'Returns error when withdrawal amount exceeds client balance.');

    $client_error = {
        code              => 'UnhandledError',
        message_to_client => "An error that is not handled here."
    };
    _cmp_deeply_validate_payment_error('CryptoWithdrawalError', $params, 'Returns the proper error for unknown error message.');

    $mocked_client->mock(validate_payment => sub { undef });
    _cmp_deeply_validate_payment_error(undef, $params, 'Returns undef when all validations passed.');

    $mocked_client->unmock_all();
};

subtest 'check_crypto_deposit' => sub {

    $cr_client_2->account('BTC');
    $cr_client_2->residence('ID');
    $cr_client_2->save();

    my $mock_CashierValidation = Test::MockModule->new('BOM::Platform::Client::CashierValidation');
    $mock_CashierValidation->mock(
        get_restricted_countries => sub {
            return ['BR'];
        });
    my $mock_auth = Test::MockModule->new("BOM::User::Client");
    $mock_auth->mock(
        fully_authenticated => sub {
            return 0;
        });

    is BOM::Platform::Client::CashierValidation::check_crypto_deposit($cr_client_2), 0, "returns 0 when the client is not from a restricted country";

    $mock_CashierValidation->mock(
        get_restricted_countries => sub {
            return [uc $cr_client_2->residence];
        });
    is BOM::Platform::Client::CashierValidation::check_crypto_deposit($cr_client_2), 1,
        "returns 1 since the client is from a restricted country and perfomed no deposit";

    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->mock('skip_authentication', sub { 1 });
    is BOM::Platform::Client::CashierValidation::check_crypto_deposit($cr_client_2), 0,
        'returns zero when landing company skip_authentication flag set';
    $mock_lc->unmock_all();

    $cr_client_2->db->dbic->dbh->do("SELECT payment.add_payment_transaction("
            . $cr_client_2->account->id
            . ", 10, 'ctc', 'crypto_cashier', 'test', NULL, NULL, 'OK', '', NULL, 1, 1, NULL)");

    is BOM::Platform::Client::CashierValidation::check_crypto_deposit($cr_client_2), 0, "deposits found, yay!";

    $mock_CashierValidation->unmock_all();
    $mock_auth->unmock_all();
};

subtest 'Cashier validation - Experimental currency' => sub {

    $app_config->system->suspend->experimental_currencies([$cr_client_2->currency]);

    my %args = (
        loginid     => $cr_client_2->loginid,
        action      => '',
        is_internal => 0,
        rule_engine => $rule_engine
    );

    my $res = BOM::Platform::Client::CashierValidation::validate(%args);

    cmp_deeply(
        $res,
        {
            error => {
                code              => 'CashierForwardError',
                message_to_client => 'This currency is temporarily suspended. Please select another currency to proceed.',
                params            => []
            },
            status => ['ExperimentalCurrency']
        },
        'Error message for experimental currencies is correct'
    );

    $app_config->payments->experimental_currencies_allowed([$cr_client_2->email]);
    ok !BOM::Platform::Client::CashierValidation::validate(%args), 'No error when the client email is allowed for experimental currencies';

    $app_config->payments->experimental_currencies_allowed([]);
    $app_config->system->suspend->experimental_currencies([]);
};

done_testing();
