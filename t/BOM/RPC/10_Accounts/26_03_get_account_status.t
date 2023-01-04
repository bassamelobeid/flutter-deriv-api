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

my $c = Test::BOM::RPC::QueueClient->new();
my $m = BOM::Platform::Token::API->new;

my $fa_data = {
    "education_level"                      => "Secondary",
    "binary_options_trading_frequency"     => "0-5 transactions in the past 12 months",
    "source_of_wealth"                     => "Company Ownership",
    "forex_trading_experience"             => "0-1 year",
    "account_turnover"                     => 'Less than $25,000',
    "cfd_trading_frequency"                => "0-5 transactions in the past 12 months",
    "employment_status"                    => "Self-Employed",
    "forex_trading_frequency"              => "0-5 transactions in the past 12 months",
    "other_instruments_trading_frequency"  => "0-5 transactions in the past 12 months",
    "income_source"                        => "Self-Employed",
    "other_instruments_trading_experience" => "0-1 year",
    "net_income"                           => '$25,000 - $50,000',
    "cfd_trading_experience"               => "0-1 year",
    "occupation"                           => "Managers",
    "binary_options_trading_experience"    => "0-1 year",
    "estimated_worth"                      => '$100,000 - $250,000',
    "employment_industry"                  => "Health"
};

subtest 'check legacy cfd_score' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $user = BOM::User->create(
        email    => 'test+legacy_cfd_score@binary.com',
        password => 'Abcd1234'
    );
    $user->add_client($client);

    $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $client->status->set('financial_risk_approval', 'system', 'Accepted approval');
    $client->status->set('crs_tin_information',     'test',   'test');

    $client->aml_risk_classification('low');
    $client->set_default_account('EUR');
    $client->financial_assessment({
        data => encode_json_utf8($fa_data),
    });
    $client->save();

    my $token  = $m->create_token($client->loginid, 'test token');
    my $result = $c->tcall('get_account_status', {token => $token});

    $client->aml_risk_classification('standard');
    $client->save();

    $result = $c->tcall('get_account_status', {token => $token});
    cmp_deeply(
        $result,
        {
            authentication => {
                attempts => {
                    count   => 0,
                    history => [],
                    latest  => undef
                },
                document => {status => "verified"},
                identity => {
                    services => {
                        idv => {
                            last_rejected       => [],
                            reported_properties => {},
                            status              => "none",
                            submissions_left    => 3,
                        },
                        manual => {status => "none"},
                        onfido => {
                            country_code         => "IDN",
                            documents_supported  => ["Driving Licence", "National Identity Card", "Passport", "Residence Permit",],
                            is_country_supported => 1,
                            last_rejected        => [],
                            reported_properties  => {},
                            status               => "none",
                            submissions_left     => 3,
                        },
                    },
                    status => "verified",
                },
                income             => {status => "none"},
                needs_verification => [],
                ownership          => {
                    requests => [],
                    status   => "none"
                },
            },
            cashier_validation => ["FinancialAssessmentRequired"],
            currency_config    => {
                EUR => {
                    is_deposit_suspended    => 0,
                    is_withdrawal_suspended => 0
                },
            },
            prompt_client_to_authenticate => 0,
            risk_classification           => "standard",
            status                        => [
                "age_verification",         "allow_document_upload",             "authenticated",           "crs_tin_information",
                "dxtrade_password_not_set", "financial_assessment_not_complete", "financial_risk_approval", "idv_disallowed",
                "mt5_password_not_set",     "trading_experience_not_complete",   "withdrawal_locked",
            ],
        },
        'financial_assessment_not_complete, chashier deposit locked'
    );

    $fa_data->{cfd_trading_experience} = '1-2 years';
    $fa_data->{cfd_trading_frequency}  = '40 transactions or more in the past 12 months';
    $client->financial_assessment({
        data => encode_json_utf8($fa_data),
    });
    $client->save();
    $result = $c->tcall('get_account_status', {token => $token});
    cmp_deeply(
        $result,
        {
            authentication => {
                attempts => {
                    count   => 0,
                    history => [],
                    latest  => undef
                },
                document => {status => "verified"},
                identity => {
                    services => {
                        idv => {
                            last_rejected       => [],
                            reported_properties => {},
                            status              => "none",
                            submissions_left    => 3,
                        },
                        manual => {status => "none"},
                        onfido => {
                            country_code         => "IDN",
                            documents_supported  => ["Driving Licence", "National Identity Card", "Passport", "Residence Permit",],
                            is_country_supported => 1,
                            last_rejected        => [],
                            reported_properties  => {},
                            status               => "none",
                            submissions_left     => 3,
                        },
                    },
                    status => "verified",
                },
                income             => {status => "none"},
                needs_verification => [],
                ownership          => {
                    requests => [],
                    status   => "none"
                },
            },
            currency_config => {
                EUR => {
                    is_deposit_suspended    => 0,
                    is_withdrawal_suspended => 0
                },
            },
            prompt_client_to_authenticate => 0,
            risk_classification           => "standard",
            status                        => [
                "age_verification",         "allow_document_upload",   "authenticated",  "crs_tin_information",
                "dxtrade_password_not_set", "financial_risk_approval", "idv_disallowed", "mt5_password_not_set",
            ],
        },
        'financial_assessment is complete, cashier is not locked, cfd score was used'
    );
};

done_testing();
