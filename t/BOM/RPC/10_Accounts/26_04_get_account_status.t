use strict;
use warnings;

use Encode;
use JSON::MaybeUTF8 qw(encode_json_utf8);
use Encode          qw(encode);
use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::BOM::RPC::QueueClient;

use Date::Utility;

use BOM::RPC::v3::Accounts;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Utility;
use BOM::User;
use BOM::Platform::Token;
use BOM::Test::Helper::FinancialAssessment;

my $c = Test::BOM::RPC::QueueClient->new();
my $m = BOM::Platform::Token::API->new;

subtest 'check cryptocurrencies cashier' => sub {
    my $user = BOM::User->create(
        email    => 'test_ust_disabled@binary.com',
        password => 'Abcd1234'
    );

    my $client_UST = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id,
    });
    my $client_USD = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id,
    });
    my $client_BTC = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id,
    });
    my $app_config = BOM::Config::Runtime->instance->app_config();

    my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
    for my $client_obj ({
            client   => $client_UST,
            currency => 'UST'
        },
        {
            client   => $client_USD,
            currency => 'USD'
        },
        {
            client   => $client_BTC,
            currency => 'BTC'
        })
    {
        $user->add_client($client_obj->{client});

        $client_obj->{client}->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $client_obj->{client}->status->set('financial_risk_approval', 'system', 'Accepted approval');
        $client_obj->{client}->status->set('crs_tin_information',     'test',   'test');

        $client_obj->{client}->aml_risk_classification('low');
        $client_obj->{client}->set_default_account($client_obj->{currency});

        $client_obj->{client}->financial_assessment({
            data => encode_json_utf8($data),
        });

        $client_obj->{client}->save();
    }

    # Add mt5 account to return mt5_additional_kyc_required tag
    $user->add_loginid("MTR1234", 'mt5', 'real', 'USD', {group => 'test/test'});

    my $token_UST = $m->create_token($client_UST->loginid, 'test token');
    my $token_USD = $m->create_token($client_USD->loginid, 'test token');
    my $token_BTC = $m->create_token($client_BTC->loginid, 'test token');

    $app_config->system->suspend->cryptocurrencies_deposit(['UST']);

    my $result_UST = $c->tcall('get_account_status', {token => $token_UST});
    my $result_USD = $c->tcall('get_account_status', {token => $token_USD});
    my $result_BTC = $c->tcall('get_account_status', {token => $token_BTC});

    ## UST Checks
    cmp_deeply($result_UST->{cashier_validation}, ["system_maintenance_deposit_outage"], "key validation for cashier_validation in UST for deposit");
    cmp_deeply(
        $result_UST->{status},
        [
            "age_verification",            "allow_document_upload",    "authenticated",           "crs_tin_information",
            "deposit_locked",              "dxtrade_password_not_set", "financial_risk_approval", "idv_disallowed",
            "mt5_additional_kyc_required", "mt5_password_not_set",
        ],
        "key validation for status in UST"
    );
    cmp_deeply(
        $result_UST->{currency_config},
        {
            UST => {
                is_deposit_suspended    => 0,
                is_withdrawal_suspended => 0
            },
        },
        "key validation for currency_config in USD"
    );

    ## US Checks
    ok(!exists $result_USD->{'cashier_validation'}, "Key 'cashier_validation' does not exist in the USD response");
    cmp_deeply(
        $result_USD->{currency_config},
        {
            USD => {
                is_deposit_suspended    => 0,
                is_withdrawal_suspended => 0
            },
        },
        "key validation for currency_config in USD"
    );
    cmp_deeply(
        $result_USD->{status},
        [
            "age_verification",         "allow_document_upload",   "authenticated",  "crs_tin_information",
            "dxtrade_password_not_set", "financial_risk_approval", "idv_disallowed", "mt5_additional_kyc_required",
            "mt5_password_not_set",
        ],
        "key validation for status in USD"
    );

    ## BTC Checks
    ok(!exists $result_BTC->{'cashier_validation'}, "Key 'cashier_validation' does not exist in the BTC response");
    cmp_deeply(
        $result_BTC->{currency_config},
        {
            BTC => {
                is_deposit_suspended    => 0,
                is_withdrawal_suspended => 0
            },
        },
        "key validation for currency_config in USD"
    );
    cmp_deeply(
        $result_BTC->{status},
        [
            "age_verification",         "allow_document_upload",   "authenticated",  "crs_tin_information",
            "dxtrade_password_not_set", "financial_risk_approval", "idv_disallowed", "mt5_additional_kyc_required",
            "mt5_password_not_set",
        ],
        "key validation for status in BTC"
    );

    $app_config->system->suspend->cryptocurrencies_withdrawal(['UST']);

    $result_UST = $c->tcall('get_account_status', {token => $token_UST});
    $result_USD = $c->tcall('get_account_status', {token => $token_USD});
    $result_BTC = $c->tcall('get_account_status', {token => $token_BTC});

    cmp_deeply(
        $result_UST->{'cashier_validation'},
        ["system_maintenance_deposit_outage", "system_maintenance_withdrawal_outage"],
        "key validation for cashier_validation in UST for deposit and withdrawal"
    );
    ok(!exists $result_USD->{'cashier_validation'}, "Key 'cashier_validation' does not exist in the USD response ");
    ok(!exists $result_BTC->{'cashier_validation'}, "Key 'cashier_validation' does not exist in the BTC response ");

    $app_config->system->suspend->cryptocurrencies_deposit([]);
    $result_UST = $c->tcall('get_account_status', {token => $token_UST});
    cmp_deeply(
        $result_UST->{'cashier_validation'},
        ["system_maintenance_withdrawal_outage"],
        "key validation for cashier_validation in UST for deposit"
    );
    cmp_deeply(
        $result_UST->{currency_config},
        {
            UST => {
                is_deposit_suspended    => 0,
                is_withdrawal_suspended => 0
            },
        },
        "key validation for currency_config in USD"
    );

    cmp_deeply(
        $result_UST->{status},
        [
            "age_verification",         "allow_document_upload",   "authenticated",  "crs_tin_information",
            "dxtrade_password_not_set", "financial_risk_approval", "idv_disallowed", "mt5_additional_kyc_required",
            "mt5_password_not_set",     "withdrawal_locked",
        ],
        "key validation for status in BTC"
    );
    $app_config->system->suspend->cryptocurrencies_withdrawal([]);

    $result_UST = $c->tcall('get_account_status', {token => $token_UST});
    ok(!exists $result_UST->{'cashier_validation'}, "Key 'cashier_validation' does not exist in the BTC response");

    cmp_deeply(
        $result_UST->{status},
        [
            "age_verification",         "allow_document_upload",   "authenticated",  "crs_tin_information",
            "dxtrade_password_not_set", "financial_risk_approval", "idv_disallowed", "mt5_additional_kyc_required",
            "mt5_password_not_set",
        ],
        "key validation for status in BTC"
    );
};

done_testing();
