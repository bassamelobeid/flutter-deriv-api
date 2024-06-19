use strict;
use warnings;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use BOM::User;
use BOM::RPC::v3::Accounts;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use utf8;
use LandingCompany::Registry;
use BOM::Config::Runtime;

my $email = 'dummy@binary.com';

my $user = BOM::User->create(
    email    => $email,
    password => '1234',
);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    date_joined    => '2021-06-06 23:59:59',
    binary_user_id => $user->id,
});
$test_client->email($email);
$test_client->save;

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    date_joined    => '2021-06-06 23:59:59',
    binary_user_id => $user->id,
});
$test_client_disabled->email($email);
$test_client_disabled->account('USD');
$test_client_disabled->status->set('disabled', 'system', 'reason');
$test_client_disabled->save;

my $self_excluded_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    date_joined    => '2021-06-06 23:59:59',
    binary_user_id => $user->id,
});
$self_excluded_client->email($email);
my $exclude_until = Date::Utility->new->epoch + 2 * 86400;
$self_excluded_client->set_exclusion->timeout_until($exclude_until);
$self_excluded_client->save;

my $test_client_duplicated = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    date_joined    => '2021-06-06 23:59:59',
    binary_user_id => $user->id,
});
$test_client_duplicated->email($email);
$test_client_duplicated->status->set('duplicate_account', 'system', 'reason');
$test_client_duplicated->save;

$user->add_client($test_client);
$user->add_client($self_excluded_client);
$user->add_client($test_client_disabled);
$user->add_client($test_client_duplicated);

$test_client->load;

my $oauth = BOM::Database::Model::OAuth->new;
my ($token) = $oauth->store_access_token_only(1, $test_client->loginid);

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    date_joined => '2021-06-06 23:59:59'
});
$test_client_vr->email($email);
$test_client_vr->save;

my ($token_vr)         = $oauth->store_access_token_only(1, $test_client_vr->loginid);
my ($token_duplicated) = $oauth->store_access_token_only(1, $test_client_duplicated->loginid);

is $test_client->default_account, undef, 'new client has no default account';

my $c = BOM::Test::RPC::QueueClient->new();

my $method = 'authorize';

subtest $method => sub {
    my $params = {
        language => 'EN',
        token    => 12345
    };

    $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');
    $params->{token} = $token;
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
                $test_client->loginid => {
                    token      => $token,
                    is_virtual => $test_client->is_virtual,
                    broker     => $test_client->broker,
                    app_id     => 1,
                }
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
                'currency'             => '',
                'currency_type'        => '',
                'excluded_until'       => $exclude_until,
                'is_disabled'          => '0',
                'is_virtual'           => '0',
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
            }
            # Duplicated client must  not be returned
        ]    # no wallet is linked
    };

    my $result = $c->call_ok($method, $params)->has_no_error->result;

    is $result->{account_list}[0]->{loginid}, $test_client->loginid;
    is $result->{account_list}[1]->{loginid}, $self_excluded_client->loginid;
    is $result->{account_list}[2]->{loginid}, $test_client_disabled->loginid;
    is scalar(@{$result->{account_list}}),    3;

    cmp_deeply($result, $expected_result, 'result is correct');

    $test_client->account('USD');
    $test_client->save;
    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    $expected_result->{stash}->{account_id} = $test_client->default_account->id;
    $expected_result->{currency}            = $expected_result->{stash}->{currency} = 'USD';
    $expected_result->{balance}             = '1000.00';

    $expected_result->{account_list}[0]->{currency}      = 'USD';
    $expected_result->{account_list}[0]->{currency_type} = 'fiat';

    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is correct');

    $params->{args}->{add_to_login_history} = 1;

    $c->call_ok($method, $params)->has_no_error;

    my $history_records = $c->call_ok(
        'login_history',
        {
            token => $token,
            args  => {limit => 1}})->has_no_error->result->{records};

    is(scalar(@{$history_records}), 0, 'no login history record is created when we authorize using oauth token');

    delete $params->{args};

    my $res = BOM::RPC::v3::Accounts::api_token({
            client => $test_client,
            args   => {
                new_token => 'Test Token',
            },
        });
    ok $res->{new_token};

    $params->{token} = $res->{tokens}->[0]->{token};
    $params->{args}->{add_to_login_history} = 1;

    $c->call_ok($method, $params)->has_no_error;

    $history_records = $c->call_ok(
        'login_history',
        {
            token => $params->{token},
            args  => {limit => 1}})->has_no_error->result->{records};

    is($history_records->[0]{action}, 'login', 'the last history is logout');
    ok($history_records->[0]{environment}, 'environment is present');

    delete $params->{args};

    $params->{token} = $token_duplicated;
    $c->call_ok($method, $params)->has_error->error_message_is("Account is disabled.", "duplicated account");

    delete $params->{args};

    subtest 'authorize for third party apps' => sub {
        my $mock_oauth_model = Test::MockModule->new('BOM::Database::Model::OAuth');
        my @official_app_ids = (1, 2);
        $mock_oauth_model->mock(
            is_official_app => sub {
                return (grep { $_ == $_[1] } @official_app_ids) ? 1 : 0;
            });

        my $app1 = $oauth->create_app({
            name         => 'Test App',
            user_id      => 1,
            scopes       => ['read', 'admin', 'trade', 'payments'],
            redirect_uri => 'https://www.example.com/',
        });

        my $app2 = $oauth->create_app({
            name         => 'Test App 2',
            user_id      => 1,
            scopes       => ['read', 'admin', 'trade', 'payments'],
            redirect_uri => 'https://www.example.com/',
        });

        BOM::Config::Runtime->instance->app_config->system->suspend->access_token_sharing(0);
        my ($unofficial_app_token1) = $oauth->store_access_token_only($app1->{app_id}, $test_client->loginid);
        $params->{token}                                                           = $unofficial_app_token1;
        $params->{source}                                                          = $app2->{app_id};
        $expected_result->{stash}->{valid_source}                                  = $app2->{app_id};
        $expected_result->{stash}->{source_type}                                   = 'unofficial';
        $expected_result->{stash}->{token}                                         = $unofficial_app_token1;
        $expected_result->{stash}->{account_tokens}{$test_client->loginid}{app_id} = $app1->{app_id};
        $expected_result->{stash}->{account_tokens}{$test_client->loginid}{token}  = $unofficial_app_token1;
        $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'Third party app can share oAuth token while flag is off');

        BOM::Config::Runtime->instance->app_config->system->suspend->access_token_sharing(1);
        my ($official_app_token) = $oauth->store_access_token_only($official_app_ids[0], $test_client->loginid);
        $params->{token}  = $official_app_token;
        $params->{source} = $app1->{app_id};
        $c->call_ok($method, $params)->has_error->error_message_is("Token is not valid for current app ID.",
            "Official app oAuth token can't be used to authorize third party app");

        my ($unofficial_app_token2) = $oauth->store_access_token_only($app2->{app_id}, $test_client->loginid);
        $params->{token} = $unofficial_app_token2;
        $c->call_ok($method, $params)->has_error->error_message_is("Token is not valid for current app ID.",
            "Third party app oAuth token can't be used by another third party app");

        $params->{source}                                                          = $app2->{app_id};
        $expected_result->{stash}->{valid_source}                                  = $app2->{app_id};
        $expected_result->{stash}->{token}                                         = $unofficial_app_token2;
        $expected_result->{stash}->{account_tokens}{$test_client->loginid}{app_id} = $app2->{app_id};
        $expected_result->{stash}->{account_tokens}{$test_client->loginid}{token}  = $unofficial_app_token2;
        $c->call_ok($method, $params)
            ->has_no_error->result_is_deeply($expected_result, 'Third party app can only be authorize by oAuth token created');

        $params->{source}                                                          = $official_app_ids[1];
        $params->{token}                                                           = $official_app_token;
        $expected_result->{stash}->{valid_source}                                  = $official_app_ids[1];
        $expected_result->{stash}->{token}                                         = $official_app_token;
        $expected_result->{stash}->{account_tokens}{$test_client->loginid}{app_id} = $official_app_ids[0];
        $expected_result->{stash}->{account_tokens}{$test_client->loginid}{token}  = $official_app_token;

        $c->call_ok($method, $params)
            ->has_no_error->result_is_deeply($expected_result, 'Third party app can only be authorize by oAuth token created');

        delete $params->{source};
        $mock_oauth_model->unmock_all;
    };

    subtest 'authorize with linked wallet' => sub {
        my $email = 'auth_wallet@example.com';
        my $user  = BOM::User->create(
            email    => $email,
            password => '1234',
        );
        # create wallet
        my $vr_wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRW',
            date_joined => '2021-06-06 23:59:59'
        });
        $vr_wallet->email($email);
        $vr_wallet->set_default_account('USD');
        $vr_wallet->deposit_virtual_funds;
        $vr_wallet->save;

        $user->add_client($vr_wallet);

        my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            date_joined => '2021-06-06 23:59:59',
        });
        $test_client_vr->email($email);
        $test_client_vr->set_default_account('USD');
        $test_client_vr->deposit_virtual_funds;
        $test_client_vr->save;
        $user->add_client($test_client_vr, $vr_wallet->loginid);

        # call authorize
        my $token_vr = $params->{token} = $oauth->store_access_token_only(1, $test_client_vr->loginid);

        is($c->call_ok($method, $params)->has_no_error->result->{is_virtual}, 1, "is_virtual is true if client is virtual");

        my $expected_result = {
            'stash' => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
                'email'                    => $email,
                'scopes'                   => ['read', 'admin', 'trade', 'payments'],
                'country'                  => 'id',
                'loginid'                  => $test_client_vr->loginid,
                'token'                    => $token_vr,
                'token_type'               => 'oauth_token',
                'account_id'               => $test_client_vr->default_account->id,
                'currency'                 => 'USD',
                'landing_company_name'     => 'virtual',
                'is_virtual'               => '1',
                'broker'                   => 'VRTC',
                'account_tokens'           => {
                    $test_client_vr->loginid => {
                        token      => $token_vr,
                        is_virtual => $test_client_vr->is_virtual,
                        broker     => $test_client_vr->broker,
                        app_id     => 1,
                    }
                },
            },
            'currency'                      => 'USD',
            'local_currencies'              => {IDR => {fractional_digits => 2}},
            'email'                         => $email,
            'scopes'                        => ['read', 'admin', 'trade', 'payments'],
            'balance'                       => '10000.00',
            'landing_company_name'          => 'virtual',
            'fullname'                      => $test_client_vr->full_name,
            'user_id'                       => $test_client_vr->binary_user_id,
            'loginid'                       => $test_client_vr->loginid,
            'is_virtual'                    => '1',
            'country'                       => 'id',
            'landing_company_fullname'      => 'Deriv Limited',
            'upgradeable_landing_companies' => ['svg'],
            'preferred_language'            => 'EN',
            'linked_to'                     => [{loginid => $vr_wallet->loginid, platform => 'dwallet'}],
            'account_list'                  => [{
                    'currency'             => 'USD',
                    'currency_type'        => 'fiat',
                    'is_disabled'          => '0',
                    'is_virtual'           => '1',
                    'landing_company_name' => 'virtual',
                    'loginid'              => $test_client_vr->loginid,
                    'account_type'         => 'binary',
                    'account_category'     => 'trading',
                    'linked_to'            => [{loginid => $vr_wallet->loginid, platform => 'dwallet'}],
                    'created_at'           => '1623023999',
                    'broker'               => $test_client_vr->broker,
                },
                {
                    'currency'             => 'USD',
                    'currency_type'        => 'fiat',
                    'is_disabled'          => '0',
                    'is_virtual'           => '1',
                    'landing_company_name' => 'virtual',
                    'loginid'              => $vr_wallet->loginid,
                    'account_type'         => 'virtual',
                    'account_category'     => 'wallet',
                    'linked_to'            => [{loginid => $test_client_vr->loginid, platform => 'dtrade'}],
                    'created_at'           => '1623023999',
                    'broker'               => $vr_wallet->broker,
                },
            ],
        };
        cmp_deeply($c->call_ok($method, $params)->has_no_error->result,
            $expected_result, 'result is correct - upgradeable even if authenticated by a virtual token');
        # call authorize for a wallet account
        my $token_wallet = $oauth->store_access_token_only(1, $vr_wallet->loginid);
        $params->{token} = $token_wallet;
        $expected_result = {
            'stash' => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
                'email'                    => $email,
                'scopes'                   => ['read', 'admin', 'trade', 'payments'],
                'country'                  => 'id',
                'loginid'                  => $vr_wallet->loginid,
                'token'                    => $token_wallet,
                'token_type'               => 'oauth_token',
                'account_id'               => $vr_wallet->default_account->id,
                'currency'                 => 'USD',
                'landing_company_name'     => 'virtual',
                'is_virtual'               => '1',
                'broker'                   => 'VRW',
                'account_tokens'           => {
                    $vr_wallet->loginid => {
                        token      => $token_wallet,
                        is_virtual => $vr_wallet->is_virtual,
                        broker     => $vr_wallet->broker,
                        app_id     => 1,
                    }
                },
            },
            'currency'                      => 'USD',
            'local_currencies'              => {IDR => {fractional_digits => 2}},
            'email'                         => $email,
            'scopes'                        => ['read', 'admin', 'trade', 'payments'],
            'balance'                       => '10000.00',
            'landing_company_name'          => 'virtual',
            'fullname'                      => $vr_wallet->full_name,
            'user_id'                       => $vr_wallet->binary_user_id,
            'loginid'                       => $vr_wallet->loginid,
            'is_virtual'                    => '1',
            'country'                       => 'id',
            'landing_company_fullname'      => 'Deriv Limited',
            'upgradeable_landing_companies' => [],
            'preferred_language'            => 'EN',
            'linked_to'                     => [{'loginid' => $test_client_vr->loginid, 'platform' => 'dtrade'}],
            'account_list'                  => [{
                    'currency'             => 'USD',
                    'currency_type'        => 'fiat',
                    'is_disabled'          => '0',
                    'is_virtual'           => '1',
                    'landing_company_name' => 'virtual',
                    'loginid'              => $test_client_vr->loginid,
                    'account_type'         => 'binary',
                    'account_category'     => 'trading',
                    'linked_to'            => [{'loginid' => $vr_wallet->loginid, 'platform' => 'dwallet'}],
                    'created_at'           => '1623023999',
                    'broker'               => $test_client_vr->broker,
                },
                {
                    'currency'             => 'USD',
                    'currency_type'        => 'fiat',
                    'is_disabled'          => '0',
                    'is_virtual'           => '1',
                    'landing_company_name' => 'virtual',
                    'loginid'              => $vr_wallet->loginid,
                    'account_type'         => 'virtual',
                    'account_category'     => 'wallet',
                    'linked_to'            => [{'loginid' => $test_client_vr->loginid, 'platform' => 'dtrade'}],
                    'created_at'           => '1623023999',
                    'broker'               => $vr_wallet->broker,
                },
            ],
        };

        cmp_deeply($c->call_ok($method, $params)->has_no_error->result,
            $expected_result, 'result is correct - no upgradeable landing company, because currenct account is a wallet');
    };

    subtest 'authorize with partial migration state(wallet is hidden from response)' => sub {
        my $email = 'auth_wallet_partial@example.com';
        my $user  = BOM::User->create(
            email    => $email,
            password => '1234',
        );
        # create wallet
        my $vr_wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRW',
            date_joined => '2021-06-06 23:59:59'
        });
        $vr_wallet->email($email);
        $vr_wallet->set_default_account('USD');
        $vr_wallet->deposit_virtual_funds;
        $vr_wallet->save;

        $user->add_client($vr_wallet);

        my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',
            date_joined => '2021-06-06 23:59:59',
        });
        $test_client_vr->email($email);
        $test_client_vr->set_default_account('USD');
        $test_client_vr->deposit_virtual_funds;
        $test_client_vr->save;
        $user->add_client($test_client_vr);

        # call authorize
        my $token_vr = $params->{token} = $oauth->store_access_token_only(1, $test_client_vr->loginid);

        my $expected_result = {
            'stash' => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
                'email'                    => $email,
                'scopes'                   => ['read', 'admin', 'trade', 'payments'],
                'country'                  => 'id',
                'loginid'                  => $test_client_vr->loginid,
                'token'                    => $token_vr,
                'token_type'               => 'oauth_token',
                'account_id'               => $test_client_vr->default_account->id,
                'currency'                 => 'USD',
                'landing_company_name'     => 'virtual',
                'is_virtual'               => '1',
                'broker'                   => 'VRTC',
                'account_tokens'           => {
                    $test_client_vr->loginid => {
                        token      => $token_vr,
                        is_virtual => $test_client_vr->is_virtual,
                        broker     => $test_client_vr->broker,
                        app_id     => 1,
                    }
                },
            },
            'currency'                      => 'USD',
            'local_currencies'              => {IDR => {fractional_digits => 2}},
            'email'                         => $email,
            'scopes'                        => ['read', 'admin', 'trade', 'payments'],
            'balance'                       => '10000.00',
            'landing_company_name'          => 'virtual',
            'fullname'                      => $test_client_vr->full_name,
            'user_id'                       => $test_client_vr->binary_user_id,
            'loginid'                       => $test_client_vr->loginid,
            'is_virtual'                    => '1',
            'country'                       => 'id',
            'landing_company_fullname'      => 'Deriv Limited',
            'upgradeable_landing_companies' => ['svg'],
            'preferred_language'            => 'EN',
            'linked_to'                     => [],
            'account_list'                  => [{
                    'currency'             => 'USD',
                    'currency_type'        => 'fiat',
                    'is_disabled'          => '0',
                    'is_virtual'           => '1',
                    'landing_company_name' => 'virtual',
                    'loginid'              => $test_client_vr->loginid,
                    'account_type'         => 'binary',
                    'account_category'     => 'trading',
                    'linked_to'            => [],
                    'created_at'           => '1623023999',
                    'broker'               => $test_client_vr->broker,
                },
            ],
        };
        cmp_deeply($c->call_ok($method, $params)->has_no_error->result,
            $expected_result, 'result is correct - upgradeable even if authenticated by a virtual token');

    };

};

=head2
subtest 'update preferred language' => sub {
    my $language = 'ZH_CN';
    my $result   = $c->call_ok(
        $method,
        {
            language => $language,
            token    => $token
        })->has_no_error->result;

    is $result->{preferred_language}, $language, 'Language set correctly.';

    $language = 'wrong';
    $result   = $c->call_ok(
        $method,
        {
            language => $language,
            token    => $token
        })->has_no_error->result;
    ok !$result->{preferred_language}, "Language didn't change correctly.";
};
=cut

subtest 'upgradeable_landing_companies' => sub {

    my $params = {};
    my $email  = 'denmark@binary.com';

    my $user = BOM::User->create(
        email    => $email,
        password => '1234',
    );

    # Create VRTC account (Denmark)
    my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'VRTC',
        residence      => 'dk',
        email          => $email,
        binary_user_id => $user->id,
    });

    $user->add_client($vr_client);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);

    # Test 1
    my $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client can upgrade to malta and maltainvest.';

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);

    # Test 2
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client can upgrade to maltainvest from virtual.';

    # Create MF account
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        residence      => 'dk',
        email          => $email,
        binary_user_id => $user->id,
    });

    $user->add_client($client);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    # Test 3
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client has upgraded all accounts.';

    my $email2 = 'belgium@binary.com';

    my $user2 = BOM::User->create(
        email    => $email2,
        password => '1234',
    );

    my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        residence   => 'be',
        email       => $email2
    });

    $user2->add_client($client2);
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client2->loginid);

    # Test 4
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client has upgraded all accounts.';

    my $email3 = 'uk@binary.com';

    my $user3 = BOM::User->create(
        email    => $email3,
        password => '1234',
    );
    my $vr_client3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        residence   => 'gb',
        email       => $email3
    });

    $user3->add_client($vr_client3);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client3->loginid);

    # Test 5
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client cannot upgrade';

    # Create MF account (United Kingdom) since MX can upgrade to maltainvest
    my $client3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
        residence   => 'gb',
        email       => $email3
    });

    $user3->add_client($client3);
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client3->loginid);

    # Test 6
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client cannot upgrade';
    my $email4 = 'de@binary.com';

    my $user4 = BOM::User->create(
        email    => $email4,
        password => '1234',
    );
    my $vr_client4 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        residence   => 'de',
        email       => $email4
    });

    $user4->add_client($vr_client4);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client4->loginid);

    # Test 7
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client can upgrade to maltainvest.';
    # Create MF account (Germany)
    my $client4 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
        residence   => 'de',
        email       => $email4
    });

    $user4->add_client($client4);
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client4->loginid);

    # Test 8
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client has upgraded all accounts.';

    my $email5 = 'id@binary.com';

    my $user5 = BOM::User->create(
        email    => $email5,
        password => '1234',
    );
    my $vr_client5 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        residence   => 'id',
        email       => $email5,
    });
    $user5->add_client($vr_client5);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client5->loginid);

    # Test 9
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['svg'], 'Client can upgrade to svg and maltainvest.';
    my $client5 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id',
        email       => $email5,
    });
    $user5->add_client($client5);
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client5->loginid);

    # Test 10
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['svg'], 'Client has upgraded all accounts.';

};

subtest 'upgradeable_landing_companies clients have not selected currency & disabled MF' => sub {
    my $params = {};
    my $email  = 'germany@binary.com';

    my $user = BOM::User->create(
        email    => $email,
        password => '1234',
    );

    # Create VRTC account (Germany)
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'VRTC',
        residence      => 'de',
        email          => $email,
        binary_user_id => $user->id,
    });
    $client_vr->account('USD');

    $user->add_client($client_vr);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);

    # Test 1
    my $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client can upgrade to maltainvest.';
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        residence      => 'de',
        email          => $email,
        binary_user_id => $user->id,
    });
    $user->add_client($client_mf);
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mf->loginid);

    # Test 2
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client already upgraded to maltainvest.';

    # Test 3
    $client_mf->status->set('duplicate_account', 1, 'test duplicate');
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client is duplicate - we can create a new maltainvest account.';
    $client_mf->status->clear_duplicate_account;
    $client_mf->save;

    # Test 4
    $client_mf->status->set('disabled', 1, 'test disabled');
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client disabled & no currency set - cannot create new maltainvest account.';

    # Test 5
    $client_mf->status->clear_disabled;
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client already upgraded to maltainvest.';
};

subtest 'upgradeable_landing_companies svg' => sub {
    my $landing_company_name = 'svg';
    my $params               = {};
    my $email                = 'indonesia@binary.com';

    my $user = BOM::User->create(
        email    => $email,
        password => '1234',
    );

    # Create VRTC account (Indonesia)
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'VRTC',
        residence      => 'za',
        email          => $email,
        binary_user_id => $user->id,
    });

    $user->add_client($client_vr);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);

    # Test 1
    my $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest', 'svg'], 'Client can upgrade to svg';

    # Create CR account
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        residence      => 'za',
        email          => $email,
        binary_user_id => $user->id,
    });
    $user->add_client($client);
    $client->status->set("disabled", 1, "test");
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);
    # Test 2
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest', 'svg'],
        'Client can upgrade to svg or maltainvest becasue his only Real svg account is disabled and he had not selected currency yet.';

    # Create CR account
    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        residence      => 'za',
        email          => $email,
        binary_user_id => $user->id,
    });
    $client_cr2->account('USD');
    $user->add_client($client_cr2);

    foreach my $currency (keys LandingCompany::Registry->by_name('svg')->legal_allowed_currencies->%*) {
        # we have already created a USD account; so all fiat currencies are unavailable.
        next if LandingCompany::Registry::get_currency_type($currency) eq 'fiat';

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            residence      => 'za',
            email          => $email,
            binary_user_id => $user->id,
        });
        $client->account($currency);
        $user->add_client($client);
    }
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr2->loginid);

    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client already upgraded to all available svg, but have also maltainvest.';

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        residence      => 'za',
        email          => $email,
        binary_user_id => $user->id,
    });
    $client->account('EUR');
    $user->add_client($client);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr2->loginid);

    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client already upgraded to all available accounts';

};

my $new_token;
subtest 'logout' => sub {
    ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);
    $c->call_ok(
        'authorize',
        {
            language => 'EN',
            token    => $token
        })->has_no_error->result;

    my $res = BOM::RPC::v3::Accounts::api_token({
            client => $test_client,
            args   => {
                new_token => 'Test Token Logout',
            },
        });
    ok $res->{new_token}, "Api token created successfully";
    my $logout_token = $res->{tokens}->[1]->{token};

    my $oauth_model = BOM::Database::Model::OAuth->new;
    my $app_id      = $oauth_model->get_app_id_by_token($token);

    my ($refresh_token) = $oauth_model->generate_refresh_token($user->{id}, $app_id);

    my $params = {
        email        => $email,
        client_ip    => '1.1.1.1',
        country_code => 'id',
        language     => 'EN',
        user_agent   => '',
        token_type   => 'oauth_token',
        token        => $token
    };

    $c->call_ok('logout', $params)->has_no_error->result_is_deeply({
            status => 1,
            stash  => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            }});

    # revoke refresh token
    my $record = $oauth_model->get_user_app_details_by_refresh_token($refresh_token);
    is $record, undef, 'refresh token was revoked successfully';

    $record = $oauth_model->get_refresh_tokens_by_user_app_id($user->{id}, $app_id);
    is scalar $record->@*, 0, 'all tokens for the user and app were revoked correctly';

    #check login history
    ($new_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);
    $c->call_ok(
        'authorize',
        {
            language => 'EN',
            token    => $new_token
        })->has_no_error->result;

    my $history_records = $c->call_ok(
        'login_history',
        {
            token => $new_token,
            args  => {limit => 1}})->has_no_error->result->{records};

    note explain $history_records;
    is($history_records->[0]{action}, 'logout', 'the last history is logout');
    like($history_records->[0]{environment}, qr/IP=1.1.1.1 IP_COUNTRY=ID User_AGENT= LANG=EN/, "environment is correct");

    $c->call_ok(
        'authorize',
        {
            language => 'EN',
            token    => $token
        })->has_error->error_message_is('The token is invalid.', 'oauth token is invalid after logout');

    my $result = $c->call_ok(
        'authorize',
        {
            language => 'EN',
            token    => $logout_token
        })->has_no_error->result;

    $history_records = $c->call_ok(
        'login_history',
        {
            token => $logout_token,
            args  => {limit => 1}})->has_no_error->result->{records};
    is($history_records->[0]{action}, 'logout', 'the last history is logout, api_token will not create login history entry until flag is set');
    like($history_records->[0]{environment}, qr/IP=1.1.1.1 IP_COUNTRY=ID User_AGENT= LANG=EN/, "environment is correct");

    $params->{token}      = $logout_token;
    $params->{token_type} = 'api_token';

    $c->call_ok('logout', $params)->has_no_error->result_is_deeply({
            status => 1,
            stash  => {
                app_markup_percentage      => 0,
                valid_source               => 1,
                source_bypass_verification => 0,
                source_type                => 'official',
            }});

    my $history_records_new = $c->call_ok(
        'login_history',
        {
            token => $logout_token,
            args  => {limit => 1}})->has_no_error->result->{records};
    is($history_records_new->[0]{action},      $history_records->[0]{action},      'the last history is logout, same as old one');
    is($history_records_new->[0]{environment}, $history_records->[0]{environment}, 'environment is correct, same as old one');
};

$token = $new_token;

subtest 'self_exclusion timeout can authorize' => sub {
    my $params = {
        language => 'en',
        token    => $token
    };
    my $timeout_until = Date::Utility->new->plus_time_interval('1d');
    $test_client->set_exclusion->timeout_until($timeout_until->epoch);
    $test_client->save();

    ok $c->call_ok($method, $params)->has_no_error->result->{loginid}, 'Self excluded client using timout_until can login';
};

subtest 'self_exclusion' => sub {
    my $params = {
        language => 'en',
        token    => $token
    };
    # This is how long I think binary.com can survive using Perl in its concurrency paradigm era.
    # If this test ever failed because of setting this date too short, we might be in bigger troubles than a failing test.
    $test_client->set_exclusion->timeout_until(0);
    $test_client->set_exclusion->exclude_until('2020-01-01');
    $test_client->save();

    ok $c->call_ok($method, $params)->has_no_error->result->{loginid}, 'Self excluded client using exclude_until can login';
};

subtest 'set system suspend logins' => sub {
    my $email = 'mah@deriv.com';
    my $user  = BOM::User->create(
        email    => $email,
        password => 'ABcd12',
    );
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'VRTC',
        residence      => 'eg',
        email          => $email,
        binary_user_id => $user->id,
    });
    $user->add_client($client_vr);

    $token = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);
    my $params = {
        language => 'EN',
        token    => $token
    };

    BOM::Config::Runtime->instance->app_config->system->suspend->logins(['VRTC']);

    $c->call_ok($method, $params)
        ->has_error->error_message_is('We can\'t take you to your account right now due to system maintenance. Please try again later.',
        'VRTC LoginDisabled');

    BOM::Config::Runtime->instance->app_config->system->suspend->logins([]);
    BOM::Config::Runtime->instance->app_config->system->suspend->all_logins(1);

    $c->call_ok($method, $params)
        ->has_error->error_message_is('We can\'t take you to your account right now due to system maintenance. Please try again later.',
        'VRTC LoginDisabled');

    BOM::Config::Runtime->instance->app_config->system->suspend->all_logins(0);
};

$self_excluded_client->set_exclusion->timeout_until(Date::Utility->new->epoch - 2 * 86400);
$self_excluded_client->status->clear_disabled;
$self_excluded_client->save;

done_testing();
