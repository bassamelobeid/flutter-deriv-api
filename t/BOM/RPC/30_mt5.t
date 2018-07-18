use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;

use Postgres::FeedDB::CurrencyConverter qw(in_USD amount_from_to_currency);

use List::Util qw();
use JSON::MaybeXS;
use Email::Folder::Search;
use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::MT5::User::Async;
use BOM::Platform::Token;
use BOM::User;
use Email::Stuffer::TestLinks;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
my $json = JSON::MaybeXS->new;
# Mocked account details
# This hash shared between three files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/30_mt5.t
#   t/BOM/RPC/05_accounts.t
#   t/lib/mock_binary_mt5.pl
my %DETAILS = (
    login    => '123454321',
    password => 'Efgh4567',
    email    => 'test.account@binary.com',
    name     => 'Test',
    group    => 'real\costarica',
    country  => 'Malta',
    balance  => '1234.56',
);

# Setup a test user
my $test_client    = create_client('CR');
my $test_client_vr = create_client('VRTC');
$test_client->email($DETAILS{email});
$test_client_vr->email($DETAILS{email});
$test_client->set_authentication('ID_DOCUMENT')->status('pass');
$test_client->save;
$test_client_vr->save;

my $user = BOM::User->create(
    email    => $DETAILS{email},
    password => 's3kr1t',
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

#since we are trying to open a new financial mt5 account we should do the financial assessment first
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

my $financial_evaluation = BOM::Platform::Account::Real::default::get_financial_assessment_score(\%financial_data);
$test_client->financial_assessment({
    data => Encode::encode_utf8($json->encode($financial_evaluation)),
});
$test_client->save;

my $m        = BOM::Database::Model::AccessToken->new;
my $token    = $m->create_token($test_client->loginid, 'test token');
my $token_vr = $m->create_token($test_client_vr->loginid, 'test token');

@BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

my $mailbox = Email::Folder::Search->new('/tmp/default.mailbox');
$mailbox->init;

# Throttle function limits requests to 1 per minute which may cause
# consecutive tests to fail without a reset.
BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

subtest 'new account' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type   => 'gaming',
            country        => 'mt',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password},
            leverage       => 100,
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
    is($c->result->{login}, $DETAILS{login}, 'result->{login}');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);

    $c->call_ok($method, $params)->has_error('error from duplicate mt5_new_account')
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'new account with switching' => sub {
    my $method = 'mt5_new_account';
    my $params = {
        language => 'EN',
        token    => $token_vr,
        # Pass this virtual account token to test switching functionality.
        #   If the user has multiple client accounts the Binary.com front-end
        #   will pass to this function whichever one is currently selected.
        #   In this case we can automatically detect that the user has
        #   another account which qualifies them to open MT5 and switch.
        args => {
            account_type   => 'gaming',
            country        => 'mt',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password},
            leverage       => 100,
        },
    };
    # Expect error because we opened an account in the previous test.
    $c->call_ok($method, $params)->has_error('error from duplicate mt5_new_account')
        ->error_code_is('MT5CreateUserError', 'error code for duplicate mt5_new_account');

    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
};

subtest 'authenticated CR client should not receive authentication request when he opens new MT5 financial account' => sub {
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    my $method = 'mt5_new_account';
    $mailbox->clear;
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'standard',
            country          => 'mt',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password},
            leverage         => 500,
        },
    };
    $c->call_ok($method, $params)->has_error('error for financial mt5_new_account')
        ->error_code_is('TINDetailsMandatory', 'tax information is mandatory for financial account');

    $test_client->tax_residence('mt');
    $test_client->tax_identification_number('111222333');
    $test_client->save;

    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
    #check inbox for emails
    my $cli_subject  = 'Authenticate your account to continue trading on MT5';
    my @client_email = $mailbox->search(
        email   => $DETAILS{email},
        subject => qr/\Q$cli_subject\E/
    );

    ok(!@client_email, "identity verification request email not sent");
};

subtest 'new CR financial accounts should receive identity verification request if account is not verified' => sub {
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $test_client->set_authentication('ID_DOCUMENT')->status('pending');
    $test_client->save;
    my $method = 'mt5_new_account';
    $mailbox->clear;
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            account_type     => 'financial',
            mt5_account_type => 'advanced',
            country          => 'mt',
            email            => $DETAILS{email},
            name             => $DETAILS{name},
            investPassword   => 'Abcd1234',
            mainPassword     => $DETAILS{password},
            leverage         => 500,
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_new_account');
    #check inbox for emails
    my $cli_subject  = 'Authenticate your account to continue trading on MT5';
    my @client_email = $mailbox->search(
        email   => $DETAILS{email},
        subject => qr/\Q$cli_subject\E/
    );

    ok(@client_email, "identity verification request email received");
};

subtest 'get settings' => sub {
    my $method = 'mt5_get_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login => $DETAILS{login},
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_get_settings');
    is($c->result->{login},   $DETAILS{login},   'result->{login}');
    is($c->result->{balance}, $DETAILS{balance}, 'result->{balance}');
    is($c->result->{country}, "mt",              'result->{country}');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_get_settings wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_get_settings wrong login');
};

subtest 'login list' => sub {
    my $method = 'mt5_login_list';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {},
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_login_list');
    is_deeply(
        $c->result,
        [{
                login      => $DETAILS{login},
                email      => $DETAILS{email},
                group      => $DETAILS{group},
                balance    => $DETAILS{balance},
                name       => 'Test',
                country    => 'mt',
                currency   => 'USD',
                manager_id => '',
                status     => 0,
                company    => undef,
                leverage   => undef,
            }
        ],
        'mt5_login_list result'
    );
};

subtest 'set settings' => sub {
    my $method = 'mt5_set_settings';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login   => $DETAILS{login},
            name    => "Test2",
            country => 'mt',
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_set_settings');
    is($c->result->{login},   $DETAILS{login}, 'result->{login}');
    is($c->result->{name},    "Test2",         'result->{name}');
    is($c->result->{country}, "mt",            'result->{country}');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_set_settings wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_set_settings wrong login');
};

subtest 'password check' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login    => $DETAILS{login},
            password => $DETAILS{password},
            type     => 'main',
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');

    $params->{args}{password} = "wrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong password')
        ->error_code_is('MT5PasswordCheckError', 'error code for mt5_password_check wrong password');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_check wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_check wrong login');
};

subtest 'password change' => sub {
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    my $method = 'mt5_password_change';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login         => $DETAILS{login},
            old_password  => $DETAILS{password},
            new_password  => 'Ijkl6789',
            password_type => 'main'
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    $params->{args}{login} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_password_change wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_password_change wrong login');

    # reset throller, test for password limit
    BOM::RPC::v3::MT5::Account::reset_throttler($test_client->loginid);
    $params->{args}->{login}        = $DETAILS{login};
    $params->{args}->{old_password} = $DETAILS{password};
    $params->{args}->{new_password} = 'Ijkl6789';
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    is($c->result, 1, 'result');

    $c->call_ok($method, $params)->has_error('error for mt5_password_change wrong login');
    is($c->result->{error}->{message_to_client}, 'Request too frequent. Please try again later.', 'change password hits rate limit');
};

subtest 'password reset' => sub {
    my $method = 'mt5_password_reset';
    $mailbox->clear;

    my $code = BOM::Platform::Token->new({
            email       => $DETAILS{email},
            expires_in  => 3600,
            created_for => 'mt5_password_reset'
        })->token;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login             => $DETAILS{login},
            new_password      => 'Ijkl6789',
            password_type     => 'main',
            verification_code => $code
        }};

    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    my $subject = 'Your MT5 password has been reset.';
    my @msgs    = $mailbox->search(
        email   => $DETAILS{email},
        subject => qr/\Q$subject\E/
    );
    ok(@msgs, "email received");

};

subtest 'investor password reset' => sub {
    my $method = 'mt5_password_reset';
    $mailbox->clear;

    my $code = BOM::Platform::Token->new({
            email       => $DETAILS{email},
            expires_in  => 3600,
            created_for => 'mt5_password_reset'
        })->token;

    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login             => $DETAILS{login},
            new_password      => 'Abcd1234',
            password_type     => 'investor',
            verification_code => $code
        }};

    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_change');
    # This call yields a truth integer directly, not a hash
    is($c->result, 1, 'result');

    my $subject = 'Your MT5 password has been reset.';
    my @msgs    = $mailbox->search(
        email   => $DETAILS{email},
        subject => qr/\Q$subject\E/
    );
    ok(@msgs, "email received");

};

subtest 'password check investor' => sub {
    my $method = 'mt5_password_check';
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            login         => $DETAILS{login},
            password      => 'Abcd1234',
            password_type => 'investor'
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_password_check');
};

subtest 'deposit' => sub {
    # User needs some real money now
    top_up $test_client, USD => 1000;

    my $method = "mt5_deposit";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_binary => $test_client->loginid,
            to_mt5      => $DETAILS{login},
            amount      => 180,
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_deposit');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    # assert that account balance is now 1000-180 = 820
    cmp_ok $test_client->default_account->load->balance, '==', 820, "Correct balance after deposited to mt5 account";

    $params->{args}{to_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_deposit wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_deposit wrong login');
};

subtest 'withdrawal' => sub {
    # TODO(leonerd): assertions in here about balance amounts would be
    #   sensitive to results of the previous test of mt5_deposit.
    my $method = "mt5_withdrawal";
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {
            from_mt5  => $DETAILS{login},
            to_binary => $test_client->loginid,
            amount    => 150,
        },
    };
    $c->call_ok($method, $params)->has_no_error('no error for mt5_withdrawal');
    ok(defined $c->result->{binary_transaction_id}, 'result has a transaction ID');

    cmp_ok $test_client->default_account->load->balance, '==', 820 + 150, "Correct balance after withdrawal";

    $params->{args}{from_mt5} = "MTwrong";
    $c->call_ok($method, $params)->has_error('error for mt5_withdrawal wrong login')
        ->error_code_is('PermissionDenied', 'error code for mt5_withdrawal wrong login');
};

done_testing();
