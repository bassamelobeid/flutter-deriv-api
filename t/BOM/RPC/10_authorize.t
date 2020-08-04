use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;
use BOM::RPC::v3::Accounts;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use utf8;
use LandingCompany::Registry;

my $email       = 'dummy@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_disabled->email($email);
$test_client_disabled->account('USD');
$test_client_disabled->status->set('disabled', 'system', 'reason');
$test_client_disabled->save;

my $self_excluded_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$self_excluded_client->email($email);
my $exclude_until = Date::Utility->new->epoch + 2 * 86400;
$self_excluded_client->set_exclusion->timeout_until($exclude_until);
$self_excluded_client->save;

my $test_client_duplicated = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_duplicated->email($email);
$test_client_duplicated->status->set('duplicate_account', 'system', 'reason');
$test_client_duplicated->save;

my $user = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($test_client);
$user->add_client($self_excluded_client);
$user->add_client($test_client_disabled);
$user->add_client($test_client_duplicated);
$test_client->load;

my $oauth = BOM::Database::Model::OAuth->new;
my ($token) = $oauth->store_access_token_only(1, $test_client->loginid);

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;

my ($token_vr)         = $oauth->store_access_token_only(1, $test_client_vr->loginid);
my ($token_duplicated) = $oauth->store_access_token_only(1, $test_client_duplicated->loginid);

is $test_client->default_account, undef, 'new client has no default account';

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

my $email_mx = 'dummy_mx@binary.com';

my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
});
$test_client_mx->email($email_mx);
$test_client_mx->save;
my $user_mx = BOM::User->create(
    email    => $email_mx,
    password => '1234',
);
$user_mx->add_client($test_client_mx);
$test_client_mx->load;
my ($token_mx) = $oauth->store_access_token_only(1, $test_client_mx->loginid);

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
        'landing_company_fullname'      => 'Binary (SVG) Ltd.',
        'upgradeable_landing_companies' => [$landing_company],
        'account_list'                  => [{
                'currency'             => '',
                'is_disabled'          => '0',
                'is_virtual'           => '0',
                'landing_company_name' => $landing_company,
                'loginid'              => $test_client->loginid
            },
            {
                'currency'             => '',
                'excluded_until'       => $exclude_until,
                'is_disabled'          => '0',
                'is_virtual'           => '0',
                'landing_company_name' => $landing_company,
                'loginid'              => $self_excluded_client->loginid,
            },
            {
                'currency'             => 'USD',
                'is_disabled'          => '1',
                'is_virtual'           => '0',
                'landing_company_name' => $landing_company,
                'loginid'              => $test_client_disabled->loginid,
            }
            # Duplicated client must  not be returned
        ],
    };

    my $result = $c->call_ok($method, $params)->has_no_error->result;

    is $result->{account_list}[0]->{loginid}, $test_client->loginid;
    is $result->{account_list}[1]->{loginid}, $self_excluded_client->loginid;
    is $result->{account_list}[2]->{loginid}, $test_client_disabled->loginid;
    is scalar(@{$result->{account_list}}), 3;

    cmp_deeply($c->call_ok($method, $params)->has_no_error->result, $expected_result, 'result is correct');

    $test_client->account('USD');
    $test_client->save;
    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    $expected_result->{stash}->{account_id} = $test_client->default_account->id;
    $expected_result->{currency} = $expected_result->{stash}->{currency} = 'USD';
    $expected_result->{balance} = '1000.00';

    $expected_result->{account_list}[0]->{currency} = 'USD';

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

    $params->{token} = $token_vr;
    is($c->call_ok($method, $params)->has_no_error->result->{is_virtual}, 1, "is_virtual is true if client is virtual");

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

};

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
    is_deeply $result->{upgradeable_landing_companies}, ['malta', 'maltainvest'], 'Client can upgrade to malta and maltainvest.';

    # Create MLT account
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'MLT',
            residence      => 'dk',
            email          => $email,
            binary_user_id => $user->id,

    });

    $user->add_client($client);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    # Test 2
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client can upgrade to maltainvest.';

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $vr_client->loginid);

    # Test 3
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client can upgrade to maltainvest from virtual.';

    # Create MF account
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        residence      => 'dk',
        email          => $email,
        binary_user_id => $user->id,
    });

    $user->add_client($client);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    # Test 4
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client has upgraded all accounts.';

    my $email2 = 'belgium@binary.com';

    my $user2 = BOM::User->create(
        email    => $email2,
        password => '1234',
    );

    # Create MLT account (Belgium)
    my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        residence   => 'be',
        email       => $email2
    });

    $user2->add_client($client2);
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client2->loginid);

    # Test 5
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['malta'], 'Client can upgrade to malta.';

    $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
        residence   => 'be',
        email       => $email2
    });

    $user2->add_client($client2);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client2->loginid);

    # Test 6
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

    # Test 7
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['iom', 'maltainvest'], 'Client can upgrade to iom and maltainvest.';
    # Create MF account (United Kingdom) since MX can upgrade to maltainvest
    my $client3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
        residence   => 'gb',
        email       => $email3
    });

    $user3->add_client($client3);
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client3->loginid);

    # Test 8
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['iom'], 'Client can upgrade to iom.';

    $client3 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MX',
        residence   => 'gb',
        email       => $email3
    });

    $user3->add_client($client3);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client3->loginid);

    # Test 9
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client has upgraded all accounts.';

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

    # Test 10
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

    # Test 11
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

    # Test 12
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['svg'], 'Client can upgrade to svg.';
    my $client5 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        residence   => 'id',
        email       => $email5,
    });
    $user5->add_client($client5);
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client5->loginid);

    # Test 13
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['svg'], 'Client has upgraded all accounts.';

};

subtest 'upgradeable_landing_companies clients have not selected currency & disabled MLT' => sub {

    my $params = {};
    my $email  = 'hungary@binary.com';

    my $user = BOM::User->create(
        email    => $email,
        password => '1234',
    );

    # Create VRTC account (Hungary)
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'VRTC',
        residence      => 'hu',
        email          => $email,
        binary_user_id => $user->id,
    });
    $client_vr->account('USD');

    $user->add_client($client_vr);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);

    my $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['malta', 'maltainvest'], 'Not disabled Virtual Client can upgrade to malta and maltainvest.';

    # Create MLT account
    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MLT',
        residence      => 'hu',
        email          => $email,
        binary_user_id => $user->id,
    });
    $user->add_client($client_mlt);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mlt->loginid);
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'],
        'Real malta Client have not selected currency yet but not disabled so can upgrade to maltainvest.';
    # make client disabled
    $client_mlt->status->set('disabled', 1, 'test disabled');
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);

    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['malta', 'maltainvest'],
        'Real client is disabled & has not selected currency yet so it can upgrade to malta and maltainvest.';
    $client_mlt->account('USD');

    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client has selected currency so cannot upgrade to malta in this case.';

    $client_mlt->status->clear_disabled;

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mlt->loginid);
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'],
        'Client has mlt account already and is not disabled so can upgrade to maltainvest.';

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        residence      => 'hu',
        email          => $email,
        binary_user_id => $user->id,
    });
    $user->add_client($client_mf);
    $client_mf->status->set('disabled', 1, 'test disabled');
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mlt->loginid);
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'],
        'Maltainvest account is disabled & currency not selected  client can upgrade to maltainvest.';
    $client_mf->status->clear_disabled;

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mlt->loginid);
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client upgraded to maltainvest.';

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

    $client_mf->status->set('disabled', 1, 'test disabled');
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);

    # Test 3
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['maltainvest'], 'Client disabled & no currency set can create new maltainvest account.';
    # create new MF account
    my $client_mf2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'MF',
        residence      => 'de',
        email          => $email,
        binary_user_id => $user->id,
    });
    #set MF acount currency
    $client_mf2->account('USD');
    $user->add_client($client_mf2);
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mf2->loginid);

    # Test 4
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
        residence      => 'id',
        email          => $email,
        binary_user_id => $user->id,
    });

    $user->add_client($client_vr);

    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);

    # Test 1
    my $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['svg'], 'Client can upgrade to svg.';

    # Create CR account
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        residence      => 'id',
        email          => $email,
        binary_user_id => $user->id,
    });
    $user->add_client($client);
    $client->status->set("disabled", 1, "test");
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);
    # Test 1
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, ['svg'],
        'Client can upgrade to svg becasue his only Real svg account is disabled and he had not selected currency yet.';

    # Create CR account
    my $client_cr2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        residence      => 'id',
        email          => $email,
        binary_user_id => $user->id,
    });
    $client_cr2->account('USD');
    $user->add_client($client_cr2);

    my $siblings = $client->real_account_siblings_information;
    my @available_currencies = BOM::RPC::v3::Utility::get_available_currencies($siblings, $client->landing_company->short);
    foreach my $currency (@available_currencies) {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code    => 'CR',
            residence      => 'id',
            email          => $email,
            binary_user_id => $user->id,
        });
        $client->account($currency);
        $user->add_client($client);
    }
    $params->{token} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr2->loginid);

    $result = $c->call_ok($method, $params)->has_no_error->result;
    is_deeply $result->{upgradeable_landing_companies}, [], 'Client already upgraded to all available svg.';

};

my $new_token;
subtest 'logout' => sub {
    ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

    my $res = BOM::RPC::v3::Accounts::api_token({
            client => $test_client,
            args   => {
                new_token => 'Test Token Logout',
            },
        });
    ok $res->{new_token}, "Api token created successfully";
    my $logout_token = $res->{tokens}->[1]->{token};

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
                source_bypass_verification => 0
            }});

    #check login history
    ($new_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);
    my $history_records = $c->call_ok(
        'login_history',
        {
            token => $new_token,
            args  => {limit => 1}})->has_no_error->result->{records};
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
                source_bypass_verification => 0
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

subtest 'self_exclusion_mx - exclude_until date set in future' => sub {
    my $params = {
        language => 'en',
        token    => $token_mx
    };
    $test_client_mx->set_exclusion->exclude_until('2020-01-01');
    $test_client_mx->save();

    ok $c->call_ok($method, $params)->has_no_error->result->{loginid}, 'Self excluded client using exclude_until can login';
};

subtest 'self_exclusion_mx - exclude_until date set in past' => sub {
    my $params = {
        language => 'en',
        token    => $token_mx
    };
    $test_client_mx->set_exclusion->exclude_until('2017-01-01');
    $test_client_mx->save();

    ok $c->call_ok($method, $params)->has_no_error->result->{loginid}, 'Self excluded client using exclude_until can login';
};

$self_excluded_client->set_exclusion->timeout_until(Date::Utility->new->epoch - 2 * 86400);
$self_excluded_client->status->clear_disabled;
$self_excluded_client->save;

done_testing();
