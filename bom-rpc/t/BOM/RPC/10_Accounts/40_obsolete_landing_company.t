use strict;
use warnings;
use utf8;
use feature 'state';
use Test::More;
use Test::Most;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::MockTime        qw(:all);
use Format::Util::Numbers qw/formatnumber financialrounding/;
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Helper::Token;
use BOM::Test::Helper::Client                  qw(create_client);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Test::BOM::RPC::QueueClient;
use BOM::Test::RPC::QueueClient;
use Business::Config::LandingCompany::Registry;

use BOM::User;
use BOM::Config::Redis;

use Email::Address::UseXS;
use Digest::SHA      qw(hmac_sha256_hex);
use BOM::Test::Email qw(:no_event);
use Scalar::Util     qw/looks_like_number/;
use JSON::MaybeUTF8  qw(encode_json_utf8);
use BOM::Platform::Token::API;
use Guard;
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use Email::Stuffer::TestLinks;
use List::Util qw/uniq/;

BOM::Test::Helper::Token::cleanup_redis_tokens();

=head2
This file contains specific tests for now-obsolete landing companies - malta (mlt) and iom (mx).
This file is only created as a precautionary check before removing major MLT/MX elements from the codebase,
after which this file can be safely deleted.
=cut

my $method;
my $email     = 'mxmlt@binary.com';
my $token_gen = BOM::Platform::Token::API->new;
my $hash_pwd  = BOM::User::Password::hashpw('jskjd8292922');
my $c         = BOM::Test::RPC::QueueClient->new();
my $user_T    = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
my $test_client_T_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MX',
    residence      => 'gb',
    citizen        => '',
    binary_user_id => $user_T->id,
});
$test_client_T_mx->email($email);

my $test_client_T_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MF',
    residence      => 'at',
    binary_user_id => $user_T->id,
});
$test_client_T_mf->email($email);

my $test_client_T_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'MLT',
    residence      => 'at',
    binary_user_id => $user_T->id,
});
$test_client_T_mlt->email($email);
$test_client_T_mlt->set_default_account('EUR');
$test_client_T_mlt->save;

$user_T->add_client($test_client_T_mlt);
$user_T->add_client($test_client_T_mx);
$user_T->add_client($test_client_T_mf);

my $token_T_mx  = $token_gen->create_token($test_client_T_mx->loginid,  'test token');
my $token_T_mf  = $token_gen->create_token($test_client_T_mf->loginid,  'test token');
my $token_T_mlt = $token_gen->create_token($test_client_T_mlt->loginid, 'test token');

my $params = {
    language   => 'EN',
    token      => $token_T_mx,
    client_ip  => '127.0.0.1',
    user_agent => 'agent',
    args       => {address1 => 'Address 1'}};
my %full_args = (
    address_line_1 => 'address line 1',
    address_line_2 => 'address line 2',
    address_city   => 'address city',
    address_state  => 'BA',
    place_of_birth => undef
);

# set_settings tests for mx/mlt

subtest 'set_settings' => sub {
    my $c = Test::BOM::RPC::QueueClient->new();
    $method = 'set_settings';
    subtest "Unspecified Citizenship value" => sub {
        $params->{token} = $token_T_mx;
        $params->{args}  = {
            %full_args,
            address_state => 'LND',
            citizen       => ''
        };
        is(
            $c->tcall($method, $params)->{error}{message_to_client},
            'Please provide complete details for your account.',
            'empty value for citizenship'
        );
    };
};

subtest 'financial_assessment' => sub {
    my $c = Test::BOM::RPC::QueueClient->new();
    is($c->tcall('get_financial_assessment', {token => $token_T_mf})->{source_of_wealth}, undef, "Financial assessment not set for MLT client");
    $method = 'set_financial_assessment';
    my $args = {
        "set_financial_assessment" => 1,
        "financial_information"    => {
            "employment_industry" => "Finance",                # +15
            "education_level"     => "Secondary",              # +1
            "income_source"       => "Self-Employed",          # +0
            "net_income"          => '$25,000 - $50,000',      # +1
            "estimated_worth"     => '$100,000 - $250,000',    # +1
            "occupation"          => 'Managers',               # +0
            "employment_status"   => "Self-Employed",          # +0
            "source_of_wealth"    => "Company Ownership",      # +0
            "account_turnover"    => 'Less than $25,000',
        }};
    $c->tcall(
        $method,
        {
            args  => $args,
            token => $token_T_mlt,
        });
    is(
        $c->tcall('get_financial_assessment', {token => $token_T_mlt})->{source_of_wealth},
        "Company Ownership",
        "Financial assessment set for MLT client"
    );
};

subtest 'reality_check' => sub {
    my $c = BOM::Test::RPC::QueueClient->new();
    $method = 'reality_check';
    $c->call_ok($method, {token => 12345})->has_error->error_message_is('The token is invalid.', 'check invalid token');

    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client_T_mlt->loginid);

    my $result = $c->call_ok($method, {token => $token})->result;

    my $token_instance = BOM::Platform::Token::API->new;
    my $details        = $token_instance->get_client_details_from_token($token);
    my $creation_time  = $details->{epoch};

    $result = $c->call_ok($method, {token => $token})->result;
    is $result->{start_time},          $creation_time,              'Start time matches oauth token creation time';
    is $result->{loginid},             $test_client_T_mlt->loginid, 'Contains correct loginid';
    is $result->{open_contract_count}, 0,                           'zero open contracts';
};

subtest 'get_limits' => sub {
    my $c              = BOM::Test::RPC::QueueClient->new();
    my $payment_limits = Business::Config::LandingCompany::Registry->new()->payment_limit();
    my $params         = {token => '12345'};

    my %withdrawal = (
        currency     => 'USD',
        amount       => -1000,
        payment_type => 'external_cashier',
        remark       => 'test withdrawal'
    );

    my %deposit = (
        currency     => 'USD',
        amount       => 11000,
        payment_type => 'external_cashier',
        remark       => 'test deposit'
    );
    subtest 'MLT' => sub {

        # Initialise a MLT test account and email and set EUR as the currency
        my $email  = 'test-mlt@binary.com';
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'MLT',
            place_of_birth => 'id',
        });
        my $user = BOM::User->create(
            email    => $email,
            password => 'dsd32e23ewef',
        );

        $client->set_default_account('EUR');

        $client->email($email);
        $client->save;
        my $loginid = $client->loginid;

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
        $params->{token} = $token;

        # Load limits for MLT, which is in EUR
        my $limits = $payment_limits->{withdrawal_limits}->{malta};

        # Test for unauthenticated accounts
        subtest 'unauthenticated' => sub {
            # Set expected results for accounts that have not had withdrawals yet
            my $expected_result = {
                stash => {
                    app_markup_percentage      => 0,
                    valid_source               => 1,
                    source_bypass_verification => 0,
                    source_type                => 'official',
                },
                'account_balance' => $client->landing_company->unlimited_balance
                ? undef
                : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
                'open_positions'                      => $client->get_limit_for_open_positions,
                'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
                'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
                'num_of_days'                         => $limits->{for_days},
                'num_of_days_limit'                   => formatnumber('price', 'EUR', $limits->{limit_for_days}),
                'lifetime_limit'                      => formatnumber('price', 'EUR', $limits->{lifetime_limit}),
                'withdrawal_for_x_days_monetary'      => '0.00',
                'withdrawal_since_inception_monetary' => '0.00',
                'remainder'                           => formatnumber('price', 'EUR', $limits->{lifetime_limit}),
                'daily_transfers'                     => ignore(),
                'daily_cumulative_amount_transfers'   => ignore(),
            };

            cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);

            # Deposit EUR 11000
            $client->smart_payment(%deposit, currency => 'EUR');
            $client->status->clear_cashier_locked;    # first-deposit will cause this in non-CR clients!

            # Withdraw EUR 1000
            my $withdraw_amount = 1000;
            $client->smart_payment(%withdrawal, currency => 'EUR');

            # After withdrawal, change withdrawn amount and remainder
            $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'EUR', $withdraw_amount);
            $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'EUR', $withdraw_amount);
            $expected_result->{'remainder'}                           = formatnumber('price', 'EUR', $limits->{lifetime_limit} - $withdraw_amount);

            cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);
        };

        # Test for authenticated accounts
        subtest 'authenticated' => sub {
            # Set client status to authenticated and save
            $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
            $client->save;
            # Set expected results to reflect withdrawn amount of USD 1000
            my $expected_result = {
                stash => {
                    app_markup_percentage      => 0,
                    valid_source               => 1,
                    source_bypass_verification => 0,
                    source_type                => 'official',
                },
                'account_balance' => $client->landing_company->unlimited_balance
                ? undef
                : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
                'open_positions'                      => $client->get_limit_for_open_positions,
                'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
                'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
                'num_of_days'                         => $limits->{for_days},
                'num_of_days_limit'                   => formatnumber('price', 'EUR', 99999999),
                'lifetime_limit'                      => formatnumber('price', 'EUR', 99999999),
                'withdrawal_since_inception_monetary' => '1000.00',
                'withdrawal_for_x_days_monetary'      => '1000.00',
                'remainder'                           => formatnumber('price', 'EUR', 99998999),
                'daily_transfers'                     => ignore(),
                'daily_cumulative_amount_transfers'   => ignore(),
            };

            cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok for fully authenticated client',);
        };
    };

# Test for MX accounts which use EUR as the currency
    subtest 'MX' => sub {
        # Initialise a MX test account and email and set EUR as the currency
        my $email  = 'test-mx@binary.com';
        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'MX',
            place_of_birth => 'id',
        });
        my $user = BOM::User->create(
            email    => $email,
            password => 'dsd32e23ewef',
        );
        $client->set_default_account('EUR');
        my $mocked_landing = Test::MockModule->new(ref($client->landing_company));
        $mocked_landing->mock('is_currency_legal', sub { 1 });

        $client->email($email);
        $client->save;
        my $loginid = $client->loginid;

        my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
        $params->{token} = $token;

        # Load limits for MX, which is in EUR
        my $limits = $payment_limits->{withdrawal_limits}->{iom};

        # Test for unauthenticated accounts
        subtest 'unauthenticated' => sub {
            # Set expected results for accounts that have not had withdrawals yet
            my $expected_result = {
                stash => {
                    app_markup_percentage      => 0,
                    valid_source               => 1,
                    source_bypass_verification => 0,
                    source_type                => 'official',
                },
                'account_balance' => $client->landing_company->unlimited_balance
                ? undef
                : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
                'open_positions'                      => $client->get_limit_for_open_positions,
                'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
                'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
                'num_of_days'                         => $limits->{for_days},
                'num_of_days_limit'                   => formatnumber('price', 'EUR', $limits->{limit_for_days}),
                'lifetime_limit'                      => formatnumber('price', 'EUR', $limits->{lifetime_limit}),
                'withdrawal_for_x_days_monetary'      => '0.00',
                'withdrawal_since_inception_monetary' => '0.00',
                'remainder'                           => formatnumber('price', 'EUR', $limits->{limit_for_days}),
                'daily_transfers'                     => ignore(),
                'daily_cumulative_amount_transfers'   => ignore(),
            };

            cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);

            # Deposit EUR 11000
            $client->smart_payment(%deposit, currency => 'EUR');
            $client->status->clear_cashier_locked;    # first-deposit will cause this in non-CR clients!

            # Withdraw EUR 1000
            my $withdraw_amount = 1000;
            $client->smart_payment(%withdrawal, currency => 'EUR');

            # After withdrawal, change withdrawn amount and remainder
            $expected_result->{'withdrawal_for_x_days_monetary'}      = formatnumber('price', 'EUR', $withdraw_amount);
            $expected_result->{'withdrawal_since_inception_monetary'} = formatnumber('price', 'EUR', $withdraw_amount);
            $expected_result->{'remainder'}                           = formatnumber('price', 'EUR', $limits->{limit_for_days} - $withdraw_amount);

            cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok',);
        };

        # Test for authenticated accounts
        subtest 'authenticated' => sub {
            # Set client status to authenticated and save
            $client->set_authentication('ID_DOCUMENT', {status => 'pass'});
            $client->save;
            # Set expected results to reflect withdrawn amount of USD 1000
            my $expected_result = {
                stash => {
                    app_markup_percentage      => 0,
                    valid_source               => 1,
                    source_bypass_verification => 0,
                    source_type                => 'official',
                },
                'account_balance' => $client->landing_company->unlimited_balance
                ? undef
                : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
                'open_positions'                      => $client->get_limit_for_open_positions,
                'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
                'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
                'num_of_days'                         => $limits->{for_days},
                'num_of_days_limit'                   => formatnumber('price', 'EUR', 99999999),
                'lifetime_limit'                      => formatnumber('price', 'EUR', $limits->{lifetime_limit}),
                'withdrawal_since_inception_monetary' => '1000.00',
                'withdrawal_for_x_days_monetary'      => '1000.00',
                'remainder'                           => formatnumber('price', 'EUR', 99998999),
                'daily_transfers'                     => ignore(),
                'daily_cumulative_amount_transfers'   => ignore(),
            };

            cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'result is ok for fully authenticated client',);
        };

        subtest 'limits with withdrawal_reversals' => sub {
            $client->smart_payment(
                %withdrawal,
                amount   => -100,
                currency => 'EUR'
            );

            my $expected_result = {
                stash => {
                    app_markup_percentage      => 0,
                    valid_source               => 1,
                    source_bypass_verification => 0,
                    source_type                => 'official',
                },
                'account_balance' => $client->landing_company->unlimited_balance
                ? undef
                : formatnumber('amount', 'EUR', $client->get_limit_for_account_balance),
                'open_positions'                      => $client->get_limit_for_open_positions,
                'payout'                              => formatnumber('price', 'EUR', $client->get_limit_for_payout),
                'market_specific'                     => BOM::Platform::RiskProfile::get_current_profile_definitions($client),
                'num_of_days'                         => $limits->{for_days},
                'num_of_days_limit'                   => formatnumber('price', 'EUR', 99999999),
                'lifetime_limit'                      => formatnumber('price', 'EUR', 99999999),
                'withdrawal_since_inception_monetary' => '1100.00',
                'withdrawal_for_x_days_monetary'      => '1100.00',
                'remainder'                           => formatnumber('price', 'EUR', 99998899),
                'daily_transfers'                     => ignore(),
                'daily_cumulative_amount_transfers'   => ignore(),
            };

            cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'correct withdrawal limits',);

            # perform a reversal
            $client->payment_doughflow(
                %withdrawal,
                transaction_type => 'withdrawal_reversal',
                amount           => 50,
                payment_fee      => -1,
                payment_method   => 'BigPay',
                trace_id         => 104,
                currency         => 'EUR',
                remark           => 'x'
            );

            $expected_result->{withdrawal_since_inception_monetary} = '1050.00';
            $expected_result->{withdrawal_for_x_days_monetary}      = '1050.00';
            $expected_result->{remainder}                           = formatnumber('price', 'EUR', 99998949);

            cmp_deeply($c->call_ok('get_limits', $params)->has_no_error->result, $expected_result, 'correct withdrawal limits after 50 EUR reversal',
            );
        }
    };
};

# Self Exclusion Tests for MX
subtest 'self_exclusion_MX' => sub {

    subtest 'self_exclusion_mx - exclude_until date set in future' => sub {

        my $params = {
            language => 'en',
            token    => $token_T_mx
        };
        $test_client_T_mx->set_exclusion->exclude_until('2020-01-01');
        $test_client_T_mx->save();

        ok $c->call_ok($method, $params)->has_no_error->result->{loginid}, 'Self excluded client using exclude_until can login';
    };

    subtest 'self_exclusion_mx - exclude_until date set in past' => sub {
        my $params = {
            language => 'en',
            token    => $token_T_mx
        };
        $test_client_T_mx->set_exclusion->exclude_until('2017-01-01');
        $test_client_T_mx->save();

        ok $c->call_ok($method, $params)->has_no_error->result->{loginid}, 'Self excluded client using exclude_until can login';
    };
};

# Sibling Accounts Tests - MF to MX/MLT and vice-versa

subtest 'Siblings accounts sync' => sub {
    my $c = BOM::Test::RPC::QueueClient->new();
    subtest 'MLT to MF' => sub {
        my $mlt_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mlt_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mlt_client->loginid);
        my ($mf_token)  = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'mlt2mf@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mlt_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mlt_token,
                args  => {
                    document_id       => '',
                    expiration_date   => '',
                    document_type     => 'proofaddress',
                    document_format   => 'png',
                    expected_checksum => '12341412412412',
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mlt_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;

        is $mlt_client->get_authentication('ID_DOCUMENT')->status, 'under_review', 'Authentication is under review for the client';
        is $mf_client->get_authentication('ID_DOCUMENT')->status,  'under_review', 'Authentication is under review for the sibling';
    };

    subtest 'MF to MLT' => sub {
        my $mlt_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mlt_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mlt_client->loginid);
        my ($mf_token)  = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'mf2mlt@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mlt_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mf_token,
                args  => {
                    document_id       => '',
                    expiration_date   => '',
                    document_type     => 'proofaddress',
                    document_format   => 'png',
                    expected_checksum => '12341412412412',
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mf_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;

        is $mf_client->get_authentication('ID_DOCUMENT')->status,  'under_review', 'Authentication is under review for the client';
        is $mlt_client->get_authentication('ID_DOCUMENT')->status, 'under_review', 'Authentication is under review for the sibling';
    };

    subtest 'MX to MF (onfido)' => sub {
        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');

        my $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MLT',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mx_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx_client->loginid);
        my ($mf_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'mltmmx2mfOnfido@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mx_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    document_id       => '',
                    expiration_date   => '',
                    document_type     => 'proofaddress',
                    document_format   => 'png',
                    expected_checksum => '12341412412412'
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;

        is $mx_client->get_authentication('ID_DOCUMENT')->status, 'under_review', 'Authentication is under review for the client';
        is $mf_client->get_authentication('ID_DOCUMENT')->status, 'under_review', 'Authentication is under review for the sibling';
        $status_mock->unmock_all;
    };

    subtest 'POI upload' => sub {
        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
        my $client_mock = Test::MockModule->new('BOM::User::Client');

        $client_mock->mock(
            'fully_authenticated',
            sub {
                0;
            });

        my $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mx_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx_client->loginid);
        my ($mf_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'docuploadpoi@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mx_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    document_id              => '1618',
                    document_type            => 'passport',
                    document_format          => 'png',
                    expected_checksum        => '124124124124',
                    document_issuing_country => 'co',
                    expiration_date          => '2117-08-11',
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;
        ok !$mx_client->get_authentication('ID_DOCUMENT'), 'POI upload does not update authentication';
        ok !$mf_client->get_authentication('ID_DOCUMENT'), 'POI upload does not update authentication';
        $status_mock->unmock_all;
        $client_mock->unmock_all;
    };

    subtest 'Fully authenticated upload' => sub {
        my $status_mock = Test::MockModule->new('BOM::User::Client::Status');
        my $client_mock = Test::MockModule->new('BOM::User::Client');

        $client_mock->mock(
            'fully_authenticated',
            sub {
                1;
            });

        my $mx_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MX',
        });
        my $mf_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',
        });
        my ($mx_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx_client->loginid);
        my ($mf_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf_client->loginid);

        my $user = BOM::User->create(
            email          => 'mx2mfFullyAuth@binary.com',
            password       => BOM::User::Password::hashpw('ASDF2222'),
            email_verified => 1,
        );
        $user->add_client($mf_client);
        $user->add_client($mx_client);

        my $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    document_id       => '',
                    expiration_date   => '',
                    document_type     => 'proofaddress',
                    document_format   => 'png',
                    expected_checksum => '252352362362'
                }})->has_no_error->result;

        my $file_id = $result->{file_id};

        $result = $c->call_ok(
            'document_upload',
            {
                token => $mx_token,
                args  => {
                    file_id => $file_id,
                    status  => 'success',
                }})->has_no_error->result;
        ok !$mx_client->get_authentication('ID_DOCUMENT'), 'Fully authenticated account does not update authentication';
        ok !$mf_client->get_authentication('ID_DOCUMENT'), 'Fully authenticated account does not update authentication';
        $status_mock->unmock_all;
        $client_mock->unmock_all;
    };
};

# Password Reset Event - MLT

subtest 'mlt client - pw reset' => sub {
    my $last_event;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->mock('emit', sub { $last_event->{$_[0]} = $_[1] });
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
        email       => 'mlt@test.com'
    });
    BOM::User->create(
        email    => $client->email,
        password => 'test'
    )->add_client($client);
    $client->account('USD');
    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

    my $params = {
        language => 'EN',
        args     => {
            verify_email => $client->email,
            type         => 'trading_platform_mt5_password_reset'
        }};

    $c->call_ok('verify_email', $params)->has_no_error;

    cmp_deeply(
        $last_event->{trading_platform_password_reset_request},
        {
            loginid    => $client->loginid,
            properties => {
                first_name       => $client->first_name,
                code             => ignore(),
                verification_url => ignore(),
                platform         => 'mt5',
            }
        },
        'password reset request event emitted'
    );
    undef $last_event;

    $params = {
        token => $token,
        args  => {
            trading_platform_password_change => 1,
            new_password                     => 'Abcd1234@',
            platform                         => 'mt5'
        }};

    $c->call_ok('trading_platform_password_change', $params)->has_no_error->result;

    cmp_deeply(
        $last_event->{trading_platform_password_changed},
        {
            loginid    => $client->loginid,
            properties => {
                contact_url => ignore(),
                first_name  => $client->first_name,
                type        => 'change',
                logins      => undef,
                platform    => 'mt5',
            }
        },
        'password change event emitted'
    );
    undef $last_event;
    $mock_events->unmock_all;
};

# MT5 Account Validation - MLT
my @emit_args;
my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_emitter->mock('emit' => sub { @emit_args = @_; });
my $mt5_account_info;
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
};

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

my $assessment_keys_mf = {
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
subtest 'mt5_validation' => sub {

    my $mocked_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
    $mocked_mt5->mock(
        'create_user' => sub {
            state $count = 1000;
            $mt5_account_info = {shift->%*};
            return Future->done({login => 'MTD' . $count++});
        },
        'deposit' => sub {
            return Future->done({status => 1});
        },
        'get_group' => sub {
            return Future->done({
                'group'    => $mt5_account_info->{group} // 'demo\p01_ts01\synthetic\svg_std_usd',
                'currency' => 'USD',
                'leverage' => 500
            });
        },
        'get_user' => sub {
            my $country_name = $mt5_account_info->{country} ? Locale::Country::Extra->new()->country_from_code($mt5_account_info->{country}) : '';
            return Future->done({%$mt5_account_info, country => $country_name // $mt5_account_info->{country}});
        },
    );
    subtest 'MLT account types - low risk' => sub {
        my $client = create_client('MLT');
        $client->set_default_account('EUR');
        $client->residence('at');
        $client->aml_risk_classification('low');
        $client->account_opening_reason('speculative');
        $client->save();

        my $user = BOM::User->create(
            email    => 'mlt+low@binary.com',
            password => 'Abcd33@!',
        );
        $user->update_trading_password('Abcd33@!');
        $user->add_client($client);
        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        #demo account
        create_mt5_account->($c, $token, $client, {account_type => 'demo'}, 'MT5NotAllowed', 'MLT client cannot gaming demo account');

        my $login = create_mt5_account->(
            $c, $token, $client,
            {
                account_type     => 'demo',
                mt5_account_type => 'financial'
            });
        ok $login, 'MLT client can create a financial demo account';
        is $mt5_account_info->{group}, 'demo\p01_ts01\financial\maltainvest_std_eur', 'correct MLT demo group';

        $login = create_mt5_account->(
            $c, $token, $client,
            {
                account_type     => 'demo',
                mt5_account_type => 'financial_stp'
            },
            'MT5NotAllowed',
            'MLT client cannot create a financial_stp demo account'
        );

        #real accounts
        create_mt5_account->($c, $token, $client, {account_type => 'gaming'}, 'MT5NotAllowed', 'MLT client cannot gaming demo account');

        create_mt5_account->(
            $c, $token, $client,
            {
                account_type     => 'financial',
                mt5_account_type => 'financial'
            },
            'FinancialAccountMissing',
            'MLT client cannot create a financial real account before upgrading to MF'
        );

        $login = create_mt5_account->(
            $c, $token, $client,
            {
                account_type     => 'financial',
                mt5_account_type => 'financial_stp'
            },
            'MT5NotAllowed',
            'MLT client cannot create a financial_stp real account'
        );
    };

    subtest 'MLT account types - high risk' => sub {
        my $client = create_client('MLT');
        $client->set_default_account('EUR');
        $client->residence('at');
        $client->aml_risk_classification('high');
        $client->account_opening_reason('speculative');
        $client->save();

        my $user = BOM::User->create(
            email    => 'mlt+high@binary.com',
            password => 'Abcd33@!',
        );
        $user->update_trading_password('Abcd33@!');
        $user->add_client($client);
        my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');

        #demo account
        create_mt5_account->($c, $token, $client, {account_type => 'demo'}, 'MT5NotAllowed', 'MLT client cannot create a gaming demo account');

        my $login = create_mt5_account->(
            $c, $token, $client,
            {
                account_type     => 'demo',
                mt5_account_type => 'financial'
            });
        ok $login, 'MLT client can create a financial demo account';
        is $mt5_account_info->{group}, 'demo\p01_ts01\financial\maltainvest_std_eur', 'correct MLT demo group';

        $login = create_mt5_account->(
            $c, $token, $client,
            {
                account_type     => 'demo',
                mt5_account_type => 'financial_stp'
            },
            'MT5NotAllowed',
            'MLT client cannot create a financial_stp demo account'
        );

        #real accounts
        financial_assessment($client, 'none');
        create_mt5_account->($c, $token, $client, {account_type => 'gaming'}, 'MT5NotAllowed', 'Gaming account not allowed');

        financial_assessment($client, 'financial_info');
        create_mt5_account->($c, $token, $client, {account_type => 'gaming'}, 'MT5NotAllowed', 'Gaming account not allowed');

        create_mt5_account->(
            $c, $token, $client,
            {
                account_type     => 'financial',
                mt5_account_type => 'financial'
            },
            'FinancialAccountMissing',
            'MLT client cannot create a financial real account before upgrading to MF'
        );

        $login = create_mt5_account->(
            $c, $token, $client,
            {
                account_type     => 'financial',
                mt5_account_type => 'financial_stp'
            },
            'MT5NotAllowed',
            'MLT client cannot create a financial_stp real account'
        );
    };

};
done_testing();

sub _get_unique_display_name {
    my @a = ('A' .. 'Z', 'a' .. 'z');
    return join '', map { $a[int(rand($#a))] } (1 .. 3);
}

sub create_mt5_account {
    my ($c, $token, $client, $args, $expected_error, $error_message) = @_;

    $client->user->update_trading_password('Abcd33@!') unless $client->user->trading_password;

    undef @emit_args;
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type   => 'demo',
            country        => 'mt',
            email          => 'test.account@binary.com',
            name           => 'MT5 lover',
            investPassword => 'Abcd311233@!',
            mainPassword   => 'Abcd33@!',
            leverage       => 100,
        },
    };

    foreach (keys %$args) { $params->{args}->{$_} = $args->{$_} }

    $mt5_account_info = {};

    my $result = $c->call_ok('mt5_new_account', $params);

    if ($expected_error) {
        $result->has_error->error_code_is($expected_error, $error_message);
        is scalar @emit_args, 0, 'No event is emitted for failed requests';
        return $c->result->{error};
    } else {
        $result->has_no_error;
        ok $mt5_account_info, 'mt5 api is called';

        is_deeply \@emit_args,
            [
            'new_mt5_signup',
            {
                cs_email         => 'support@binary.com',
                language         => 'EN',
                loginid          => $client->loginid,
                mt5_group        => $mt5_account_info->{group},
                mt5_login_id     => $c->result->{login},
                account_type     => $params->{args}->{account_type}     // '',
                sub_account_type => $params->{args}->{mt5_account_type} // '',
            },
            ];
        return $c->result->{login};
    }
}

sub financial_assessment {
    my ($client, $type) = @_;
    my %data;
    if ($client->landing_company->short eq 'maltainvest') {
        %data = map { $_ => $financial_data_mf{$_} } ($assessment_keys_mf->{$type}->@*);
        %data = %financial_data_mf if $type eq 'full';
    } else {
        %data = map { $_ => $financial_data{$_} } ($assessment_keys->{$type}->@*);
        %data = %financial_data if $type eq 'full';
    }

    $client->financial_assessment({data => JSON::MaybeUTF8::encode_json_utf8(\%data)});
    $client->save();

}
