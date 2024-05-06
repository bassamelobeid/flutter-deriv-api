use strict;
use warnings;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(create_client);
use BOM::Platform::Token::API;
use BOM::User;
use BOM::RPC::v3::Accounts;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use utf8;
use LandingCompany::Registry;
use BOM::Config::Runtime;

my $c = BOM::Test::RPC::QueueClient->new();
my $m = BOM::Platform::Token::API->new;

my $email = 'dummy@binary.com';

my $user = BOM::User->create(
    email    => $email,
    password => '1234',
);

my $test_client = create_client(
    'CR', undef,
    {
        email          => $email,
        date_joined    => '2021-06-06 23:59:59',
        binary_user_id => $user->id,
    });

my $test_client_disabled = create_client(
    'CR', undef,
    {
        email          => $email,
        date_joined    => '2021-06-06 23:59:59',
        binary_user_id => $user->id,
    });
$test_client_disabled->account('USD');
$test_client_disabled->status->set('disabled', 'system', 'reason');

my $self_excluded_client = create_client(
    'CR', undef,
    {
        email          => $email,
        date_joined    => '2021-06-06 23:59:59',
        binary_user_id => $user->id,
    });
my $exclude_until = Date::Utility->new->epoch + 2 * 86400;
$self_excluded_client->set_exclusion->timeout_until($exclude_until);
$self_excluded_client->save;

my $test_client_duplicated = create_client(
    'CR', undef,
    {
        email          => $email,
        date_joined    => '2021-06-06 23:59:59',
        binary_user_id => $user->id,
    });
$test_client_duplicated->status->set('duplicate_account', 'system', 'reason');

$user->add_client($test_client);
$user->add_client($self_excluded_client);
$user->add_client($test_client_disabled);
$user->add_client($test_client_duplicated);

my $oauth = BOM::Database::Model::OAuth->new;
my ($token) = $oauth->store_access_token_only(1, $test_client->loginid);

my $test_client_vr = create_client(
    'VRTC', undef,
    {
        email       => $email,
        date_joined => '2021-06-06 23:59:59'
    });

my ($token_vr)         = $oauth->store_access_token_only(1, $test_client_vr->loginid);
my ($token_duplicated) = $oauth->store_access_token_only(1, $test_client_duplicated->loginid);

is $test_client->default_account, undef, 'new client has no default account';

my $email_mx = 'dummy_mx@binary.com';
my $user_mx  = BOM::User->create(
    email    => $email_mx,
    password => '1234',
);
my $test_client_mx = create_client(
    'MX', undef,
    {
        email          => $email_mx,
        date_joined    => '2021-06-06 23:59:59',
        binary_user_id => $user_mx->id,
    });

$user_mx->add_client($test_client_mx);
$test_client_mx->load;
my ($token_mx) = $oauth->store_access_token_only(1, $test_client_mx->loginid);

my $email_mx_2 = 'dummy_mx_2@binary.com';
my $user_mx_2  = BOM::User->create(
    email    => $email_mx_2,
    password => '1234',
);
my $test_client_mx_2 = create_client(
    'MX', undef,
    {
        email          => $email_mx_2,
        date_joined    => '2021-06-06 23:59:59',
        binary_user_id => $user_mx_2->id,
    });

$user_mx_2->add_client($test_client_mx_2);
$test_client_mx_2->load;
my ($token_mx_2) = $oauth->store_access_token_only(1, $test_client_mx_2->loginid);

my $method = 'authorize';

subtest "$method with multiple tokens" => sub {
    my $params = {
        language => 'EN',
        token    => $token,
        args     => {tokens => [$token_mx, '1111']}};

    $c->call_ok($method, $params)
        ->has_error->error_message_is("Invalid/duplicate token for a loginid provided.", 'Invalid/duplicate token for a loginid provided.');

    $params->{args}{tokens} = [$token_mx, $token_mx_2];

    $c->call_ok($method, $params)->has_error->error_message_is('Token is not valid for current user.', "check tokens don't belong to user");

    my $cr_login  = create_client('CR',   undef, {date_joined => '2021-06-06 23:59:59'});
    my $cr2_login = create_client('CR',   undef, {date_joined => '2021-06-06 23:59:59'});
    my $vr_login  = create_client('VRTC', undef, {date_joined => '2021-06-06 23:59:59'});

    $user->add_client($cr_login);
    $user->add_client($cr2_login);
    $user->add_client($vr_login);

    my $cr_loginid  = $cr_login->loginid;
    my $cr2_loginid = $cr2_login->loginid;
    my $vr_loginid  = $vr_login->loginid;
    my $cr_token    = BOM::Database::Model::OAuth->new->store_access_token_only(1, $cr_login->loginid);
    my $cr2_token   = BOM::Database::Model::OAuth->new->store_access_token_only(1, $cr2_login->loginid);
    my $vr_token    = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_login->loginid);

    $params->{args}{tokens} = [$cr_token, $cr2_token, $vr_token];

    subtest "use valid token of other accounts of user" => sub {
        my $result = $c->call_ok($method, $params)->has_no_error->result;

        my $landing_company = 'svg';

        my $expected_result = {
            'stash' => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
                'email'                    => 'dummy@binary.com',
                'scopes'                   => ['read', 'admin', 'trade', 'payments'],
                'country'                  => 'id',
                'loginid'                  => $test_client->loginid,
                'token'                    => $token,
                'token_type'               => 'oauth_token',
                'account_id'               => '',
                'currency'                 => '',
                'landing_company_name'     => $landing_company,
                'is_virtual'               => '0',
                'broker'                   => 'CR',
                'account_tokens'           => {
                    $cr_loginid => {
                        token      => $cr_token,
                        broker     => $cr_login->broker,
                        is_virtual => $cr_login->is_virtual,
                        app_id     => 1,
                    },
                    $cr2_loginid => {
                        token      => $cr2_token,
                        broker     => $cr2_login->broker,
                        is_virtual => $cr2_login->is_virtual,
                        app_id     => 1,
                    },
                    $vr_loginid => {
                        token      => $vr_token,
                        broker     => $vr_login->broker,
                        is_virtual => $vr_login->is_virtual,
                        app_id     => 1,
                    },
                    $test_client->loginid => {
                        token      => $token,
                        broker     => $test_client->broker,
                        is_virtual => $test_client->is_virtual,
                        app_id     => 1,
                    },
                },
            },
            'currency'                      => '',
            'local_currencies'              => {IDR => {fractional_digits => 2}},
            'email'                         => 'dummy@binary.com',
            'scopes'                        => ['read', 'admin', 'trade', 'payments'],
            'balance'                       => '0.00',
            'landing_company_name'          => $landing_company,
            'fullname'                      => $test_client->full_name,
            'user_id'                       => $test_client->binary_user_id,
            'loginid'                       => $test_client->loginid,
            'is_virtual'                    => '0',
            'country'                       => 'id',
            'landing_company_fullname'      => 'Deriv (SVG) LLC',
            "preferred_language"            => 'EN',
            'upgradeable_landing_companies' => [$landing_company],
            'linked_to'                     => [],
            'account_list'                  => [{
                    'currency'             => '',
                    'currency_type'        => '',
                    'is_disabled'          => '0',
                    'is_virtual'           => '0',
                    'landing_company_name' => $landing_company,
                    'loginid'              => $test_client->loginid,
                    'account_type'         => 'binary',
                    'account_category'     => 'trading',
                    'linked_to'            => [],
                    'created_at'           => '1623023999',
                    'broker'               => $test_client->broker,
                },
                {
                    'linked_to'            => [],
                    'is_virtual'           => 0,
                    'currency'             => '',
                    'currency_type'        => '',
                    'is_disabled'          => 0,
                    'account_category'     => 'trading',
                    'loginid'              => $cr_loginid,
                    'created_at'           => 1623023999,
                    'landing_company_name' => 'svg',
                    'account_type'         => 'binary',
                    'broker'               => $cr_login->broker,
                },
                {
                    'account_category'     => 'trading',
                    'loginid'              => $cr2_loginid,
                    'landing_company_name' => 'svg',
                    'created_at'           => 1623023999,
                    'account_type'         => 'binary',
                    'linked_to'            => [],
                    'is_virtual'           => 0,
                    'currency'             => '',
                    'currency_type'        => '',
                    'is_disabled'          => 0,
                    'broker'               => $cr2_login->broker,
                },
                {
                    'currency'             => '',
                    'currency_type'        => '',
                    'linked_to'            => [],
                    'landing_company_name' => 'virtual',
                    'loginid'              => $vr_loginid,
                    'is_disabled'          => 0,
                    'account_type'         => 'binary',
                    'account_category'     => 'trading',
                    'is_virtual'           => 1,
                    'created_at'           => 1623023999,
                    'broker'               => $vr_login->broker,

                },
                {
                    'currency'             => '',
                    'currency_type'        => '',
                    'is_disabled'          => '0',
                    'is_virtual'           => '0',
                    'excluded_until'       => $exclude_until,
                    'landing_company_name' => $landing_company,
                    'loginid'              => $self_excluded_client->loginid,
                    'account_type'         => 'binary',
                    'account_category'     => 'trading',
                    'linked_to'            => [],
                    'created_at'           => '1623023999',
                    'broker'               => $self_excluded_client->broker,
                },
                {
                    'currency'             => 'USD',
                    'currency_type'        => 'fiat',
                    'is_disabled'          => '1',
                    'is_virtual'           => '0',
                    'landing_company_name' => $landing_company,
                    'loginid'              => $test_client_disabled->loginid,
                    'account_type'         => 'binary',
                    'account_category'     => 'trading',
                    'linked_to'            => [],
                    'created_at'           => '1623023999',
                    'broker'               => $test_client_disabled->broker,
                },

            ]};

        cmp_deeply($result, $expected_result, 'result is correct');
    };

    subtest "api and oauth token combination" => sub {
        my $cr_api_token = BOM::Platform::Token::API->new->create_token($cr_loginid, 'Test', ['read']);
        $params->{args}{tokens} = [$cr_api_token, $vr_token];
        $c->call_ok($method, $params)
            ->has_error->error_message_is("Invalid/duplicate token for a loginid provided.", 'Api token provided in tokens.');
    };

    subtest "add token of account not belonging to user" => sub {
        my $test_client_mf = create_client(
            'MF', undef,
            {
                email       => 'dummy@deriv.com',
                date_joined => '2021-06-06 23:59:59'
            });
        my ($token_mf) = $oauth->store_access_token_only(1, $test_client_mf->loginid);

        $params->{args}{tokens} = [$cr_token, $vr_token, $token_mf];
        $c->call_ok($method, $params)->has_error->error_message_is('Token is not valid for current user.', 'Token is not valid for current user.');
    };

    subtest "invalid token added" => sub {
        $params->{args}{tokens} = [$cr_token, $vr_token, 'xxxxxxxxxx'];
        $c->call_ok($method, $params)->has_error->error_message_is("Invalid/duplicate token for a loginid provided.", 'Unknown token.');
    };

    subtest "duplicated token added" => sub {
        $params->{args}{tokens} = [$cr_token, $vr_token, $token_mx, $token_mx];
        $c->call_ok($method, $params)->has_error->error_message_is('Invalid/duplicate token for a loginid provided.', 'Duplicate token for loginid.');
    };

    subtest "token with different app_id" => sub {
        my $cr3_login = create_client('CR', undef, {date_joined => '2021-06-06 23:59:59'});
        $user->add_client($cr3_login);
        my $cr3_token = BOM::Database::Model::OAuth->new->store_access_token_only(2, $cr3_login->loginid);

        $params->{args}{tokens} = [$cr_token, $vr_token, $cr3_token];
        $c->call_ok($method, $params)
            ->has_error->error_message_is('Token is not valid for current app ID.', 'Token is not valid for current app ID.');
    };

    subtest "multiple api tokens" => sub {
        my $cr_api_token  = BOM::Platform::Token::API->new->create_token($cr_loginid,  'Test', ['read']);
        my $cr2_api_token = BOM::Platform::Token::API->new->create_token($cr2_loginid, 'Test', ['read']);
        $params->{token} = $cr2_api_token;
        $params->{args}{tokens} = [$cr_api_token];
        $c->call_ok($method, $params)->has_error->error_message_is("None of the provided tokens are valid.", 'Api token provided in tokens.');
    };

    subtest "Add a non available account" => sub {
        $params->{args}{tokens} = [$cr2_token, $token_mx];
        $params->{token} = $vr_token;
        $cr2_login->status->set('duplicate_account', 1, 'test non available account');
        $c->call_ok($method, $params)->has_error->error_message_is('Token is not valid for current user.', 'Non available account.');
    };

    subtest "suspended token in account_tokens" => sub {
        $params->{args}{tokens} = [$cr_token];

        BOM::Config::Runtime->instance->app_config->system->suspend->logins([$cr_loginid]);

        $c->call_ok($method, $params)
            ->has_error->error_message_is('We can\'t take you to your account right now due to system maintenance. Please try again later.',
            'Token suspended');

        BOM::Config::Runtime->instance->app_config->system->suspend->all_logins(0);
    };

};

subtest 'get account tokens' => sub {
    my $auth_token    = '11111';
    my $token_details = {
        loginid => $test_client_vr->loginid,
    };
    my $params        = {args => {tokens => ['12345', '67890']}};
    my $tokens_result = BOM::RPC::v3::Authorize::_get_account_tokens($params, $auth_token, $token_details);
    ok $tokens_result->{error}->{error}{code} eq 'InvalidToken', 'invalid token';

    $auth_token = $token_vr;
    $params     = {args => {tokens => [$token_mx_2, $token_mx]}};

    $tokens_result = BOM::RPC::v3::Authorize::_get_account_tokens($params, $auth_token, $token_details);
    my $expected_result = {
        $test_client_vr->loginid => {
            token  => $token_vr,
            app_id => 1
        },
        $test_client_mx->loginid => {
            token  => $token_mx,
            app_id => 1
        },
        $test_client_mx_2->loginid => {
            token  => $token_mx_2,
            app_id => 1
        },
    };

    is_deeply($tokens_result->{result}, $expected_result, 'get tokens by loginid');

    $params->{args}{tokens} = [$token_mx, '2222'];
    $tokens_result = BOM::RPC::v3::Authorize::_get_account_tokens($params, $auth_token, $token_details);

    ok $tokens_result->{error}->{error}{code} eq 'InvalidToken', 'invalid token';
};

subtest 'check for valid loginids' => sub {
    my $account_list = [{loginid => 'CR123'}, {loginid => 'CR456'}, {loginid => 'CR789'}];

    my $valid_loginids = BOM::RPC::v3::Authorize::_valid_loginids_for_user($account_list, ['CR123'], 'CR123');
    ok $valid_loginids, 'loginid belongs to user';

    $valid_loginids = BOM::RPC::v3::Authorize::_valid_loginids_for_user($account_list, ['CR123', 'CR456', 'CR789'], 'CR123');
    ok $valid_loginids, 'all loginid belongs to user';

    $valid_loginids = BOM::RPC::v3::Authorize::_valid_loginids_for_user($account_list, ['CR123'], 'CR123');
    ok $valid_loginids, 'ok, no additional loginid';

    $valid_loginids = BOM::RPC::v3::Authorize::_valid_loginids_for_user($account_list, ['CR123', 'CR456', 'CR987'], 'CR123');
    ok !$valid_loginids, 'not all loginid belongs to user';

    $valid_loginids = BOM::RPC::v3::Authorize::_valid_loginids_for_user($account_list, ['CR123', 'CR456', 'CR789', 'CR0123'], 'CR123');
    ok !$valid_loginids, 'extra loginid not belongs to user';
};

$self_excluded_client->set_exclusion->timeout_until(Date::Utility->new->epoch - 2 * 86400);
$self_excluded_client->status->clear_disabled;
$self_excluded_client->save;

done_testing();
