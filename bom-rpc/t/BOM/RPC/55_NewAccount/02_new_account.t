use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;
use Test::Fatal    qw(lives_ok exception);
use Test::MockTime qw(set_fixed_time restore_time);

use Date::Utility;
use MojoX::JSON::RPC::Client;
use POSIX qw/ ceil /;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token;
use BOM::User::Client;
use BOM::User::Wallet;
use BOM::Service;
use Email::Stuffer::TestLinks;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Customer;
use BOM::Database::Model::OAuth;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::RPC::v3::MT5::Account;
use Deriv::TradingPlatform::MT5::UserRights qw(get_new_account_permissions);
use utf8;
use Syntax::Keyword::Try;

use IO::Pipe;

my $app = BOM::Database::Model::OAuth->new->create_app({
    name    => 'test',
    scopes  => '{read,admin,trade,payments}',
    user_id => 1
});
my $app_id = $app->{app_id};
isnt($app_id, 1, 'app id is not 1');    # There was a bug that the created token will be always app_id 1; We want to test that it is fixed.

my $fixed_time = Date::Utility->new('2018-02-15');
set_fixed_time($fixed_time->epoch);

my %emitted;
my $emit_data;
my $mock_events  = Test::MockModule->new('BOM::Platform::Event::Emitter');
my $mock_context = Test::MockModule->new('BOM::Rules::Context');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;

        $emit_data = $data;

        my $loginid = $data->{loginid};

        ok !$emitted{$type . '_' . $loginid}, "First (and hopefully unique) signup event for $loginid" if $type eq 'signup';

        $emitted{$type . '_' . $loginid}++;
    });

my $dd_inc_metrics = {};
my $dd_tags        = {};
my $mock_datadog   = Test::MockModule->new('BOM::RPC::v3::NewAccount');

$mock_datadog->mock(
    'stats_inc' => sub {
        my $metric_name = shift;
        my $tags        = shift;
        $dd_inc_metrics->{$metric_name}++;
        $dd_tags->{$metric_name} = $tags;
    },
);

my $email = sprintf('Test%.5f@binary.com', rand(999));
my $rpc_ct;
my ($method, $params, $client_details);

$client_details = {
    salutation             => 'hello',
    last_name              => 'Vostrov' . rand(999),
    first_name             => 'Evgeniy' . rand(999),
    date_of_birth          => '1987-09-04',
    address_line_1         => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01',
    address_line_2         => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01',
    address_city           => 'Samara',
    address_postcode       => '112233',
    phone                  => '+79272075932',
    secret_question        => 'test',
    secret_answer          => 'test',
    account_opening_reason => 'Speculative',
    citizen                => 'de',
    place_of_birth         => 'de',
};

$params = {
    language => 'EN',
    source   => $app_id,
    country  => 'ru',
    args     => {},
};
# Used it to enable wallet migration in progress
sub _enable_wallet_migration {
    my $user_id    = shift;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->system->suspend->wallets(0);
    my $redis_rw = BOM::Config::Redis::redis_replicated_write();
    $redis_rw->set(
        "WALLET::MIGRATION::IN_PROGRESS::" . $user_id, 1,
        EX => 30 * 60,
        "NX"
    );
}
# Used it to disable wallet migration
sub _disable_wallet_migration {
    my $user_id    = shift;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->system->suspend->wallets(1);
    my $redis_rw = BOM::Config::Redis::redis_replicated_write();
    $redis_rw->del("WALLET::MIGRATION::IN_PROGRESS::" . $user_id);
}

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

$method = 'new_account_virtual';
subtest $method => sub {
    $params->{args}->{residence} = 'id';

    my @invalid_passwords = ('82341231258', '123abcasdda', '123ABC!@ASD', '1@3Abad', 'ABCdefdd');

    for my $pw (@invalid_passwords) {
        $params->{args}->{client_password}   = $pw;
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PasswordError', 'If password is weak it should return error')
            ->error_message_is('Your password must be 8 to 25 characters long. It must include lowercase and uppercase letters, and numbers.',
            "If password ($pw) is weak it should return error_message");
    }

    $params->{args}->{client_password}   = '123Abcd!';
    $params->{args}->{verification_code} = 'wrong token';

    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('InvalidToken', 'If email verification_code is wrong it should return error')
        ->error_message_is('Your token has expired or is invalid.', 'If email verification_code is wrong it should return error_message');

    # first contact is limited within 30d, anytime earlier is less useful for marketing
    my $date_first_contact = Date::Utility->new->minus_time_interval('30d')->date_yyyymmdd;

    $params->{args}->{utm_source}         = 'google.com';
    $params->{args}->{utm_medium}         = 'email';
    $params->{args}->{utm_campaign}       = 'spring sale';
    $params->{args}->{gclid_url}          = 'FQdb3wodOkkGBgCMrlnPq42q8C';
    $params->{args}->{date_first_contact} = $date_first_contact;
    $params->{args}->{signup_device}      = 'mobile';
    $params->{args}->{email_consent}      = 1;
    $params->{user_agent}                 = "Mozilla";

    my $expected_utm_data = {
        utm_campaign_id  => 111017190001,
        utm_content      => '2017_11_09_O_TGiving_NoSt_SDTest_NoCoup_2',
        utm_term         => 'MyLink123',
        utm_ad_id        => 'f521708e-db6e-478b-9731-8243a692c2d5',
        utm_adgroup_id   => 45637,
        utm_gl_client_id => 3541,
        utm_msclk_id     => 5,
        utm_fbcl_id      => 6,
        utm_adrollclk_id => 7,
    };

    map { $params->{args}->{$_} = $expected_utm_data->{$_} } keys %$expected_utm_data;
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $params->{args}->{client_password} = $email;
    $rpc_ct->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('PasswordError', 'If password is same as email, it should returns error')
        ->error_message_is('You cannot use your email address as your password.', 'If password is the same as email it should returns error_message');

    $email                               = lc $email;
    $params->{args}->{client_password}   = '123Abas!';
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
        ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
        ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
        ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');
    my $new_loginid = $rpc_ct->result->{client_id};

    ok $new_loginid =~ /^VRTC\d+/, 'new VR loginid';
    is $emit_data->{properties}->{type},       'trading', 'type=trading';
    is $emit_data->{properties}->{subtype},    'virtual', 'subtype=virtual';
    is $emit_data->{properties}->{user_agent}, 'Mozilla', 'user_agent=Mozilla';

    my $token_db = BOM::Database::Model::AccessToken->new();
    my $tokens   = $token_db->get_all_tokens_by_loginid($new_loginid);
    is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");

    my $user_data = BOM::Service::user(
        context    => BOM::Test::Customer::get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $email,
        attributes => [qw(utm_source gclid_url date_first_contact signup_device utm_data email_consent)],
    );
    is $user_data->{status}, 'ok', 'user service call succeeded';

    is $user_data->{attributes}{utm_source},         'google.com',                 'utm registered as expected';
    is $user_data->{attributes}{gclid_url},          'FQdb3wodOkkGBgCMrlnPq42q8C', 'gclid value returned as expected';
    is $user_data->{attributes}{date_first_contact}, $date_first_contact,          'date first contact value returned as expected';
    is $user_data->{attributes}{signup_device},      'mobile',                     'signup_device value returned as expected';
    is $user_data->{attributes}{email_consent},      1,                            'email consent for new account is 1 for residence under svg';
    is_deeply decode_json_utf8($user_data->{attributes}{utm_data}), $expected_utm_data, 'utm data registered as expected';

    my ($resp_loginid, $t, $uaf) =
        @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
    is $resp_loginid, $new_loginid, 'correct oauth token';

    my $oauth_token   = $rpc_ct->result->{oauth_token};
    my $refresh_token = $rpc_ct->result->{refresh_token};

    like $refresh_token, qr/^r1/, 'Got a refresh token';

    ok $emitted{"signup_$resp_loginid"}, "signup event emitted";

    subtest 'duplicate email' => sub {
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('duplicate email', 'Correct error code')->error_message_is(
            'Your provided email address is already in use by another Login ID. According to our terms and conditions, you may only register once through our site.',
            'Correct error message'
        );
    };

    subtest 'European client - de' => sub {
        my $vr_email = BOM::Test::Customer::get_random_email_address();
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence} = 'de';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');
        is $dd_inc_metrics->{'bom_rpc.v_3.new_account_real_success.count'}, undef, "new account real count is not increased for virtual account";
        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $vr_email,
            attributes => [qw(email_consent)],
        );
        is $user_data->{status},                    'ok', 'user service call succeeded';
        is $user_data->{attributes}{email_consent}, 1,    'email consent for new account is 1 for european clients - de';

    };

    subtest 'European client - gb' => sub {
        my $vr_email = BOM::Test::Customer::get_random_email_address();
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence} = 'gb';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('invalid residence', 'gb is not allowed to sign up');
    };

    subtest 'non-pep self declaration' => sub {

        # without non-pep declaration
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => 'new_email' . rand(999) . 'vr_non_pep@binary.com',
            created_for => 'account_opening'
        )->token;
        $params->{args}->{residence} = 'de';

        delete $params->{args}->{non_pep_declaration};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('virtual account created without checking non-pep declaration');
        my $client = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});
        is $client->non_pep_declaration_time, undef, 'non_pep_declaration_time is empty for virtual account';

        # with non-pep declaration
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => 'new_email' . rand(999) . 'vr_non_pep@binary.com',
            created_for => 'account_opening'
        )->token;
        $params->{args}->{non_pep_declaration} = 1;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('virtual account created with checking non-pep declaration');
        $client = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});
        is $client->non_pep_declaration_time, undef,
            'non_pep_self_declaration_time is empty for virtual accounts even when rpc is called with param set to 1';
    };

    subtest 'fatca self declaration' => sub {
        # without non-pep declaration
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => 'new_email' . rand(999) . 'vr_fatca@binary.com',
            created_for => 'account_opening'
        )->token;
        $params->{args}->{residence} = 'de';

        delete $params->{args}->{fatca_declaration};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('virtual account created without checking fatca declaration');
        my $client = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});
        is $client->fatca_declaration_time, undef, 'fatca_declaration_time is empty for virtual account';
        is $client->fatca_declaration,      undef, 'fatca_declaration is empty for virtual account';

        # with fatca declaration
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => 'new_email' . rand(999) . 'vr_fatca@binary.com',
            created_for => 'account_opening'
        )->token;
        $params->{args}->{fatca_declaration} = 1;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('virtual account created with fatca declaration');
        $client = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});
        is $client->fatca_declaration_time, undef, 'fatca_declaration_time is empty for virtual accounts even when rpc is called with param set to 1';
        is $client->fatca_declaration,      undef, 'fatca_declaration is empty for virtual accounts even when rpc is called with param set to 1';
    };

    subtest 'email consent given' => sub {
        my $vr_email = BOM::Test::Customer::get_random_email_address();
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence}     = 'de';
        $params->{args}->{email_consent} = 1;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $vr_email,
            attributes => [qw(email_consent)],
        );
        is $user_data->{status},                    'ok', 'user service call succeeded';
        is $user_data->{attributes}{email_consent}, 1,    'email consent is given';
    };

    subtest 'email consent not given' => sub {
        my $vr_email = BOM::Test::Customer::get_random_email_address();
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence}     = 'de';
        $params->{args}->{email_consent} = 0;
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $vr_email,
            attributes => [qw(email_consent)],
        );
        is $user_data->{status},                    'ok', 'user service call succeeded';
        is $user_data->{attributes}{email_consent}, 0,    'email consent is not given';
    };

    subtest 'email consent undefined' => sub {
        my $vr_email = BOM::Test::Customer::get_random_email_address();
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{residence} = 'de';
        delete $params->{args}->{email_consent};

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $vr_email,
            attributes => [qw(email_consent)],
        );
        is $user_data->{status},                    'ok', 'user service call succeeded';
        is $user_data->{attributes}{email_consent}, 1,    'email consent is accepted by default';
    };

    subtest 'invalid utm data' => sub {
        my $vr_email = BOM::Test::Customer::get_random_email_address();
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $vr_email,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{utm_content}  = '$content';
        $params->{args}->{utm_term}     = 'term2$';
        $params->{args}->{utm_campaign} = 'camp$ign2';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');

        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, "signup event emitted";

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $vr_email,
            attributes => [qw(utm_data)],
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';
        my $utm_data = decode_json_utf8($user_data->{attributes}{utm_data});

        foreach my $key (keys $utm_data->%*) {
            if ($params->{args}->{$key} !~ /^[\w\s\.\-_]{1,100}$/) {
                is $utm_data->{$key}, undef, "$key is skipped as expected";
            } else {
                is $utm_data->{$key}, $params->{args}->{$key}, "$key has been set correctly";
            }
        }
    };

    subtest 'account_category' => sub {
        my $email_c = BOM::Test::Customer::get_random_email_address();
        $params->{args}                      = {};
        $params->{args}->{residence}         = 'lb';
        $params->{args}->{client_password}   = '123Abas!';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email_c,
            created_for => 'account_opening'
        )->token;

        $params->{args}->{account_category} = 'trading';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');

    };

    subtest 'signup suspended email verification' => sub {
        $params->{args} = {};
        BOM::Config::Runtime->instance->app_config->email_verification->suspend->virtual_accounts(1);

        my $email         = 'suspended_email_verification' . rand(999) . '@deriv.com';
        my $invalid_email = 'invalid_email' . rand(999) . '.@binary.com';

        $params->{args}->{residence}         = 'id';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;
        $params->{args}->{client_password} = '1234Abcd!';

        my %initial_emissions = %emitted;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InputValidationFailed',
            'If signup with suspended email verification enabled, it should return error.')
            ->error_message_is('This field is required.', 'If signup with suspended email verification enabled, it should return error_message.')
            ->error_details_is({field => 'email'},
            'If signup with suspended email verification enabled, it should return detail with missing field.');

        is %initial_emissions, %emitted, 'no new emissions made for failed signup attempt';

        $params->{args}->{email} = $invalid_email;

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidEmail',
            'If signup with suspended email verification and email is invalid, it should return error.')
            ->error_message_is('This email address is invalid.',
            'If signup with suspended email verification enabled and email is invalid, it should return error_message.');

        is %initial_emissions, %emitted, 'no new emissions made for failed signup attempt';

        $params->{args}->{verification_code} = 'big cat wrong code';
        $params->{args}->{email}             = $email;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('If email verification is suspended - account created successfully')
            ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');

        is %initial_emissions + 1, %emitted, 'new signup event emission made for successful signup';
        ok $emitted{'signup_' . $rpc_ct->result->{client_id}}, 'signup event emitted';

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $email,
            attributes => [qw(utm_data)],
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';
        ok !$user_data->{attributes}{email_verified}, 'If signup when suspended email verification, user is not email verified.';

        BOM::Config::Runtime->instance->app_config->email_verification->suspend->virtual_accounts(0);
    };
};

$method = 'new_account_real';
$params = {
    language => 'EN',
    source   => $app_id,
    country  => 'ru',
    args     => {},
};

subtest $method => sub {
    subtest 'Check new account permission' => sub {
        # We have made a decision to disable trading upon mt5 account creation
        is(Deriv::TradingPlatform::MT5::UserRights::get_new_account_permissions(), 485, 'MT5 New account permission check');
    };

    subtest 'Auth client' => sub {
        my $customer = BOM::Test::Customer->create({
                email    => BOM::Test::Customer::get_random_email_address(),
                password => BOM::User::Password::hashpw('Abcd33!@'),
            },
            [{
                    name        => 'CR',
                    broker_code => 'CR',
                },
            ]);

        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        $params->{token} = 'wrong token';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        delete $params->{token};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        $params->{token} = $customer->get_client_token('CR');

        {
            my $module = Test::MockModule->new('BOM::User::Client');
            $module->mock('new', sub { });

            $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'It should check auth');
        }
    };

    subtest 'Create new account' => sub {
        my $customer = BOM::Test::Customer->create({
                email    => BOM::Test::Customer::get_random_email_address(),
                password => BOM::User::Password::hashpw('Abcd33!@'),
            },
            [{
                    name        => 'VRTC',
                    broker_code => 'VRTC',
                },
            ]);

        $emit_data = {};
        $params->{token} = $customer->get_client_token('VRTC');

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        isnt $result->{error}->{code}, 'InvalidAccount', 'No error with duplicate details but residence not provided so it errors out';

        $params->{args}->{residence}      = 'id';
        $params->{args}->{address_state}  = 'Sumatera';
        $params->{args}->{place_of_birth} = 'id';
        $params->{user_agent}             = 'Mozilla';

        @{$params->{args}}{keys %$client_details} = values %$client_details;

        $params->{args}{citizen} = "at";

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('email unverified', 'It should return error if email unverified')
            ->error_message_is('Your email address is unverified.', 'It should return error if email unverified');

        my $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $customer->get_user_id(),
            attributes => {email_verified => 1},
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        $params->{args}->{phone} = 'a1234567890';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidPhone', 'Phone number could not contain alphabetic characters')
            ->error_message_is(
            'Please enter a valid phone number, including the country code (e.g. +15417541234).',
            'Phone number is invalid only if it contains alphabetic characters'
            );

        $params->{args}->{phone} = '1234256789';

        # Added to check, it will not allow if we have any migration in progress
        _enable_wallet_migration($customer->get_user_id());
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('WalletMigrationInprogress', 'The wallet migration is in progress.')
            ->error_message_is(
            'This may take up to 2 minutes. During this time, you will not be able to deposit, withdraw, transfer, and add new accounts.');
        _disable_wallet_migration($customer->get_user_id());

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv (SVG) LLC',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'svg', 'It should return new account data');
        is $dd_inc_metrics->{'bom_rpc.v_3.new_account_real_success.count'}, 1, "new account real count is increased for new real account";
        cmp_deeply $dd_tags->{'bom_rpc.v_3.new_account_real_success.count'}, {tags => ["rpc:new_account_real"]}, 'data dog tags';

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';
        is $emit_data->{properties}->{type},       'trading', 'type=trading';
        is $emit_data->{properties}->{subtype},    'real',    'subtype=real';
        is $emit_data->{properties}->{user_agent}, 'Mozilla', 'user_agent=Mozilla';

        my $token_db = BOM::Database::Model::AccessToken->new();
        my $tokens   = $token_db->get_all_tokens_by_loginid($new_loginid);
        is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';

        my $new_client = BOM::User::Client->new({loginid => $new_loginid});
        $new_client->status->set('duplicate_account', 'system', 'Duplicate account - currency change');

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv (SVG) LLC',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} },
            'svg', 'It should return new account data if one of the account is marked as duplicate');
        is $dd_inc_metrics->{'bom_rpc.v_3.new_account_real_success.count'}, 2, "new account real count is increased for new real account";
        cmp_deeply $dd_tags->{'bom_rpc.v_3.new_account_real_success.count'}, {tags => ["rpc:new_account_real"]}, 'data dog tags';
        $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/,       'new CR loginid';
        ok $emitted{"signup_$new_loginid"}, "signup event emitted";
        # check disabled case
        my $disabled_client = BOM::User::Client->new({loginid => $new_loginid});
        $disabled_client->status->set('disabled', 'system', 'reason');
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv (SVG) LLC',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} },
            'svg', 'It should return new account data if one of the account is marked as disabled & account currency is not selected.');
        is $dd_inc_metrics->{'bom_rpc.v_3.new_account_real_success.count'}, 3, "new account real count is increased for new real account";
        cmp_deeply $dd_tags->{'bom_rpc.v_3.new_account_real_success.count'}, {tags => ["rpc:new_account_real"]}, 'data dog tags';
        $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CR\d+$/, 'new CR loginid';
        # check disabled but account currency selected case
        $new_client = BOM::User::Client->new({loginid => $new_loginid});

        $disabled_client->set_default_account("USD");
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('SetExistingAccountCurrency', 'correct error code.')
            ->error_message_is("Please set the currency for your existing account $new_loginid, in order to create more accounts.",
            'It should return expected error message');

        # cannot change immutable fields (coming from the dup account)
        $params->{args}->{secret_answer} = 'asdf';

        # could bring flakiness if not mocked
        my $mock_client = Test::MockModule->new(ref($new_client));
        $mock_client->mock(
            'benched',
            sub {
                return 0;
            });

        $new_client->set_default_account("USD");
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('CannotChangeAccountDetails', 'correct error code.')
            ->error_message_is("You may not change these account details.", 'It should return expected error message')
            ->error_details_is({changed => [qw/secret_answer/]});

        delete $params->{args}->{secret_answer};

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error;
        is $dd_inc_metrics->{'bom_rpc.v_3.new_account_real_success.count'}, 4,     "new account real count is increased for new real account";
        is $rpc_ct->result->{refresh_token},                                undef, 'No refresh token generated for the second account';
        ok $rpc_ct->result->{oauth_token} =~ /^a1-.*/, 'OAuth token generated for the second account';

        $new_loginid = $rpc_ct->result->{client_id};
        $new_client  = BOM::User::Client->new({loginid => $new_loginid});
        $new_client->set_default_account("GBP");

        $params->{args}->{secret_answer} = 'test';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error;
        is $rpc_ct->result->{refresh_token}, undef, 'No refresh token generated for the third account';
        ok $rpc_ct->result->{oauth_token} =~ /^a1-.*/, 'OAuth token generated for the third account';
    };

    subtest 'Whitespaces should be trimmed' => sub {
        $email = BOM::Test::Customer::get_random_email_address();

        $params->{args}->{email} = $email;

        $params->{args}->{residence}       = 'id';
        $params->{args}->{client_password} = 'verylongDDD1!';
        delete $params->{token};

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok('new_account_virtual', $params)
            ->has_no_system_error->has_no_error('If verification code is ok - account created successfully');

        $params->{token} = $rpc_ct->result->{oauth_token};

        $params->{args}->{currency} = 'USD';

        my @fields_should_be_trimmed = grep {
            my $element = $_;
            not grep { $element eq $_ } qw(phone address_state date_of_birth)
        } BOM::User::Client::PROFILE_FIELDS_IMMUTABLE_DUPLICATED->@*;

        foreach my $field (@fields_should_be_trimmed) {
            $params->{args}->{$field} = "Test with trailing whitespace ";
        }

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create fiat currency account')
            ->result_value_is(sub { shift->{currency} },      'USD',  'fiat currency account currency is USD')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'fiat currency account currency type is fiat');

        my $cl_usd = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});

        foreach my $field (@fields_should_be_trimmed) {

            is $cl_usd->{$field}, "Test with trailing whitespace", "Whitespaces are trimmed";
        }

    };

    subtest 'Create new client untrimmed fields exception' => sub {
        $email = BOM::Test::Customer::get_random_email_address();

        $params->{args}->{email} = $email;

        $params->{args}->{residence}       = 'id';
        $params->{args}->{client_password} = 'verylongDDD1!';
        delete $params->{token};

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok('new_account_virtual', $params)
            ->has_no_system_error->has_no_error('If verification code is ok - account created successfully');

        $params->{token} = $rpc_ct->result->{oauth_token};

        $params->{args}->{currency} = 'USD';

        my @fields_should_be_trimmed = grep {
            my $element = $_;
            not grep { $element eq $_ } qw(phone address_state date_of_birth)
        } BOM::User::Client::PROFILE_FIELDS_IMMUTABLE_DUPLICATED->@*;

        foreach my $field (@fields_should_be_trimmed) {
            $params->{args}->{$field} = "Fail with trailing whitespace ";
        }

        my $mocked_utility = Test::MockModule->new('BOM::User::Utility');
        $mocked_utility->mock('trim_immutable_client_fields' => sub { shift });
        warning_like {
            $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('invalid', 'Exception thrown for client creation.')
                ->error_message_is('Sorry, account opening is unavailable.', 'Error message is correct.');
        }
        [
            qr/new row for relation "client" violates check constraint "immutable_fields_are_trimmed"/,
            qr/new row for relation "client" violates check constraint "immutable_fields_are_trimmed"/
        ],
            'expected database constraint violation warning';

        $mocked_utility->unmock_all;
    };

    subtest 'Create multiple accounts in CR' => sub {
        $params->{args}->{secret_answer} = 'test';
        $email = BOM::Test::Customer::get_random_email_address();

        delete $params->{token};
        $params->{args}->{email}           = $email;
        $params->{args}->{client_password} = 'verylongDDD1!';

        $params->{args}->{residence}         = 'id';
        $params->{args}->{utm_source}        = 'google.com';
        $params->{args}->{utm_medium}        = 'email';
        $params->{args}->{utm_campaign}      = 'spring sale';
        $params->{args}->{gclid_url}         = 'FQdb3wodOkkGBgCMrlnPq42q8C';
        $params->{args}->{affiliate_token}   = 'first';
        $params->{args}->{fatca_declaration} = 1;
        delete $params->{args}->{non_pep_declaration};

        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        $rpc_ct->call_ok('new_account_virtual', $params)
            ->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
            ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
            ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');

        my $client_cr = {
            first_name    => 'James' . rand(999),
            last_name     => 'Brown' . rand(999),
            date_of_birth => '1960-01-02',
            phone         => sprintf("+792720756%02d", rand(99)),
        };

        @{$params->{args}}{keys %$client_cr} = values %$client_cr;

        $params->{token} = $rpc_ct->result->{oauth_token};

        $params->{args}->{currency} = 'USD';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create fiat currency account')
            ->result_value_is(sub { shift->{currency} },      'USD',  'fiat currency account currency is USD')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'fiat currency account currency type is fiat');

        my $cl_usd = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});

        $params->{token} = $rpc_ct->result->{oauth_token};

        ok $cl_usd->non_pep_declaration_time, 'Non-pep self declaration time is set';
        $cl_usd->non_pep_declaration_time('2018-01-01');

        ok $cl_usd->fatca_declaration_time, 'Fatca self declaration time is set';
        $cl_usd->fatca_declaration_time('2018-01-01');

        ok $cl_usd->fatca_declaration, 'Fatca self declaration boolean is set';
        ok $cl_usd->fatca_declaration(1);

        is $cl_usd->authentication_status, 'no', 'Client is not authenticated yet';

        $cl_usd->set_authentication('ID_DOCUMENT', {status => 'pass'});
        $cl_usd->save;

        is $cl_usd->authentication_status, 'scans', 'Client is fully authenticated with scans';
        $cl_usd->save;

        is $cl_usd->myaffiliates_token, 'first', 'client affiliate token set succesfully';
        $params->{args}->{currency} = 'EUR';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error('cannot create second fiat currency account')
            ->error_code_is('CurrencyTypeNotAllowed', 'error code is CurrencyTypeNotAllowed');

        delete $params->{args}->{fatca_declaration};
        # Delete all params except currency. Info from prior account should be used
        $params->{args} = {'currency' => 'BTC'};
        $params->{args}->{affiliate_token} = 'second';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create crypto currency account, reusing info')
            ->result_value_is(sub { shift->{currency} },      'BTC',    'crypto account currency is BTC')
            ->result_value_is(sub { shift->{currency_type} }, 'crypto', 'crypto account currency type is crypto');

        my $loginid = $rpc_ct->result->{client_id};

        $rpc_ct->call_ok('get_account_status', {token => $params->{token}});

        my $is_authenticated = grep { $_ eq 'authenticated' } @{$rpc_ct->result->{status}};

        is $is_authenticated, 1, 'New client is also authenticated';

        my $cl_btc = BOM::User::Client->new({loginid => $loginid});

        is $cl_btc->myaffiliates_token, 'first', 'client affiliate token not changed';

        is($cl_btc->financial_assessment(), undef, 'new client has no financial assessment if previous client has none as well');

        is $client_cr->{$_}, $cl_btc->$_, "$_ is correct on created account" for keys %$client_cr;

        ok(defined($cl_btc->binary_user_id), 'BTC client has a binary user id');
        ok(defined($cl_usd->binary_user_id), 'USD client has a binary_user_id');
        is $cl_btc->binary_user_id,           $cl_usd->binary_user_id,    'Both BTC and USD clients have the same binary user id';
        is $cl_btc->non_pep_declaration_time, '2018-01-01 00:00:00',      'Pep self-declaration time is the same for CR siblings';
        is $cl_btc->fatca_declaration_time,   '2018-01-01 00:00:00',      'Fatca self-declaration time is the same for CR siblings';
        is $cl_btc->fatca_declaration,        $cl_usd->fatca_declaration, 'Fatca self-declaration boolean is the same for CR siblings';

        $params->{args}->{currency} = 'BTC';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error('cannot create another crypto currency account with same currency')
            ->error_code_is('DuplicateCurrency', 'error code is DuplicateCurrency');

        # Set financial assessment for default client before making a new account to check if new account inherits the financial assessment data
        my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
        $cl_usd->financial_assessment({
            data => encode_json_utf8($data),
        });
        $cl_usd->save();

        $params->{args}->{currency}            = 'LTC';
        $params->{args}->{non_pep_declaration} = 1;
        $params->{args}->{fatca_declaration}   = 1;

        delete $params->{args}->{place_of_birth};
        delete $params->{args}->{citizen};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create second crypto currency account')
            ->result_value_is(sub { shift->{currency} },      'LTC',    'crypto account currency is LTC')
            ->result_value_is(sub { shift->{currency_type} }, 'crypto', 'crypto account currency type is crypto');

        my $cl_ltc = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});

        cmp_ok($cl_ltc->citizen, 'eq', $cl_usd->citizen, 'Citizenship cannot be changed');

        is_deeply(
            decode_json_utf8($cl_ltc->financial_assessment->{data}),
            decode_json_utf8($cl_usd->financial_assessment->{data}),
            "new client financial assessment is the same as old client financial_assessment"
        );

        $rpc_ct->call_ok('get_settings', {token => $rpc_ct->result->{oauth_token}})->result;
        cmp_ok($rpc_ct->result->{place_of_birth}, 'eq', $client_details->{place_of_birth}, 'place_of_birth cannot be changed');
    };

};

$method = 'new_account_maltainvest';
$params = {
    language => 'EN',
    source   => $app_id,
    country  => 'ru',
    args     => BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1)};

subtest $method => sub {
    my $customer;

    subtest 'Initialization' => sub {
        lives_ok {
            $customer = BOM::Test::Customer->create({
                    email      => BOM::Test::Customer::get_random_email_address(),
                    password   => BOM::User::Password::hashpw('Abcd33!@'),
                    first_name => '',
                    citizen    => '',
                },
                [{
                        name        => 'VRTC',
                        broker_code => 'VRTC',
                    },
                ]);
        }
        'Initial users and clients';
    };

    subtest 'Auth client' => sub {
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        $params->{token} = 'wrong token';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        delete $params->{token};
        $rpc_ct->call_ok($method, $params)->has_no_system_error->error_code_is('InvalidToken', 'It should return error: InvalidToken');

        $params->{token} = $customer->get_client_token('VRTC');

        {
            my $module = Test::MockModule->new('BOM::User::Client');
            $module->mock('new', sub { });

            $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('AuthorizationRequired', 'It should check auth');
        }
    };

    subtest 'resident self-declaration' => sub {
        my $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer::get_random_email_address(),
                password       => BOM::User::Password::hashpw('Abcd33!@'),
                email_verified => 1,
                first_name     => 'tsett',
                residence      => 'es',
            },
            [{
                    name        => 'VRTC',
                    broker_code => 'VRTC',
                },
            ]);

        $params->{token}                           = $customer->get_client_token('VRTC');
        $params->{args}{tax_residence}             = 'es';
        $params->{args}{tax_identification_number} = 'MRTSVT79M29F8P9P';
        $params->{args}{accept_risk}               = 1;
        $params->{args}{citizen}                   = "es";
        $params->{args}{currency}                  = 'EUR';
        $params->{args}{date_of_birth}             = '1986-05-10';

        my $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'get_attributes',
            user_id    => $customer->get_user_id(),
            attributes => [qw(residence)],
        );
        ok $user_data->{status} eq 'ok', 'User service read ok';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('ResidentSelfDeclarationRequired',
            'It should return error: ResidentSelfDeclarationRequired')->error_message_is('Resident Self Declaration required for country.',
            'It should return error_message: Resident Self Declaration required for country.')
            ->error_details_is({residence => $user_data->{attributes}{residence}});

        delete $params->{args};
        $params->{args} = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);
    };

    subtest 'new maltainvest account with resident self declaration' => sub {
        my $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer::get_random_email_address(),
                password       => BOM::User::Password::hashpw('Abcd33!@'),
                email_verified => 1,
                first_name     => 'tsett',
                residence      => 'es',
            },
            [{
                    name        => 'VRTC',
                    broker_code => 'VRTC',
                },
            ]);

        $params->{token}                             = $customer->get_client_token('VRTC');
        $params->{args}->{tax_residence}             = 'es';
        $params->{args}->{tax_identification_number} = 'MRTSVT79M29F8P9P';
        $params->{args}->{accept_risk}               = 1;
        $params->{args}->{citizen}                   = "es";
        $params->{args}->{residence}                 = 'es';
        $params->{args}->{currency}                  = 'EUR';
        $params->{args}->{resident_self_declaration} = 1;
        $params->{args}->{date_of_birth}             = '1986-05-10';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv Investments (Europe) Limited',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'maltainvest', 'It should return new account data')
            ->result_value_is(sub { shift->{currency} },      'EUR',  'It should return new account data')
            ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^MF\d+/, 'new MF loginid';

        my $cl = BOM::User::Client->new({loginid => $new_loginid});

        ok $cl->status->resident_self_declaration, 'Resident self declaration is set';

        delete $params->{args};
        $params->{args} = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);
    };

    subtest 'Create new account maltainvest' => sub {
        my $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes_force',
            user_id    => $customer->get_user_id(),
            attributes => {residence => 'ng'},
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        $params->{args}->{accept_risk} = 1;
        delete $params->{args}->{non_pep_declaration};
        delete $params->{args}->{fatca_declaration};
        $params->{token} = $customer->get_client_token('VRTC');

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        is $result->{error}->{code}, 'PermissionDenied', 'It should return error if client residence does not fit for maltainvest';

        $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes_force',
            user_id    => $customer->get_user_id(),
            attributes => {residence => 'de'},
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('email unverified', 'It should return error if email unverified')
            ->error_message_is('Your email address is unverified.', 'It should return error if email unverified');

        $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $customer->get_user_id(),
            attributes => {email_verified => 1},
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        delete $params->{args}->{accept_risk};

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if client does not accept risk')
            ->error_message_is('Please provide complete details for your account.', 'It should return error if client does not accept risk');

        @{$params->{args}}{keys %$client_details} = values %$client_details;

        $params->{args}->{residence}  = 'de';
        $params->{args}->{first_name} = '';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for your account.',
            'It should return error if missing details: "tax_residence", "tax_identification_number", "first_name", "residence"')
            ->error_details_is({missing => ["tax_residence", "tax_identification_number", "first_name"]});

        $params->{args}->{first_name}  = $client_details->{first_name};
        $params->{args}->{accept_risk} = 1;
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for your account.',
            'It should return error if missing any details: "tax_residence", "tax_identification_number"')
            ->error_details_is({missing => ["tax_residence", "tax_identification_number"]});

        $params->{args}->{place_of_birth}            = "de";
        $params->{args}->{tax_residence}             = "de,nl";
        $params->{args}->{tax_identification_number} = "111222";

        $params->{args}->{citizen} = '';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_message_is('Please provide complete details for your account.', 'It should return error if missing any details: citizen')
            ->error_details_is({missing => ["citizen"]});
        $params->{args}->{citizen} = 'at';

        my $mocked_client = Test::MockModule->new('BOM::User::Client');
        $mocked_client->redefine(residence => sub { return 'ng' });
        $params->{args}->{residence} = 'ng';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied', 'It should return error if residence does not fit with maltainvest')
            ->error_message_is('Permission denied.', 'It should return error if residence does not fit with maltainvest');
        $mocked_client->unmock_all;

        $params->{args}->{residence} = 'de';

        $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes_force',
            user_id    => $customer->get_user_id(),
            attributes => {citizen => ''},
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        $params->{args}->{citizen} = 'xx';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidCitizenship', 'Correct error code for invalid citizenship for maltainvest')
            ->error_message_is(
            'Sorry, our service is not available for your country of citizenship.',
            'Correct error message for invalid citizenship for maltainvest'
            );

        #if citizenship is from restricted country but residence is valid,it shouldn't throw any error
        $params->{args}->{citizen} = 'ir';

        $params->{args}->{phone} = 'a1234567890';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidPhone', 'Phone number could not contain alphabetic characters')
            ->error_message_is(
            'Please enter a valid phone number, including the country code (e.g. +15417541234).',
            'Phone number is invalid only if it contains alphabetic characters'
            );
        delete $params->{args}->{phone};

        $params->{args}->{employment_status} = 'Employed';
        delete $params->{args}->{employment_industry};

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('IncompleteFinancialAssessment', 'financial assessment should be complete')
            ->error_message_is('The financial assessment is not complete');

        # employement_industry and occupation should default to unemployed if employment_status is unemployed/self-employed
        $params->{args}->{employment_status} = 'Unemployed';
        delete $params->{args}->{employment_industry};
        delete $params->{args}->{occupation};

        $params->{args}->{citizen}          = 'de';
        $params->{args}->{residence}        = 'de';
        $params->{args}->{address_postcode} = '';

        $user_data = BOM::Service::user(
            context    => $customer->get_user_service_context(),
            command    => 'update_attributes_force',
            user_id    => $customer->get_user_id(),
            attributes => {
                residence        => 'de',
                address_postcode => ''
            },
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        my @fields_should_be_trimmed = grep {
            my $element = $_;
            not grep { $element eq $_ } qw(phone address_state date_of_birth)
        } BOM::User::Client::PROFILE_FIELDS_IMMUTABLE_DUPLICATED->@*;

        foreach my $field (@fields_should_be_trimmed) {
            $params->{args}->{$field} = "Test with trailing whitespace ";
        }

        $params->{args}->{currency} = 'GBP';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('CurrencyNotAllowed', 'Currency GBP is disabled for signup for maltainvest')
            ->error_message_is('The provided currency GBP is not selectable at the moment.');

        delete $params->{args}->{currency};

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv Investments (Europe) Limited',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'maltainvest', 'It should return new account data');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^MF\d+/, 'new MF loginid';

        my $cl = BOM::User::Client->new({loginid => $new_loginid});

        foreach my $field (@fields_should_be_trimmed) {
            is $cl->{$field}, "Test with trailing whitespace", "Whitespaces are trimmed";
        }

        ok($cl->status->financial_risk_approval, 'For mf accounts we will set financial risk approval status');
        is $cl->non_pep_declaration_time, $fixed_time->datetime_yyyymmdd_hhmmss,
            'non_pep_declaration_time is auto-initialized with no non_pep_declaration in args';

        is $cl->fatca_declaration_time, $fixed_time->datetime_yyyymmdd_hhmmss,
            'fatca_declaration_time is auto-initialized with no fatca_declaration in args';

        is $cl->fatca_declaration, 1, 'fatca_declaration is auto-initialized with no fatca_declaration in args';

        is $cl->status->crs_tin_information->{reason}, 'Client confirmed tax information', "CRS status is set";

        my ($resp_loginid, $t, $uaf) =
            @{BOM::Database::Model::OAuth->new->get_token_details($rpc_ct->result->{oauth_token})}{qw/loginid creation_time ua_fingerprint/};
        is $resp_loginid, $new_loginid, 'correct oauth token';

        ok $emitted{"signup_$new_loginid"}, "signup event emitted";

        # check disabled case
        my $disabled_client = BOM::User::Client->new({loginid => $new_loginid});
        $disabled_client->status->set('disabled', 'system', 'reason');
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('NewAccountLimitReached', 'correct error code.')
            ->error_message_is('You have created all accounts available to you.', 'It should return expected error message');

        # check disabled but account currency selected case
        $disabled_client->set_default_account("USD");
        my $mock_user = Test::MockModule->new('BOM::User');
        $mock_user->redefine(bom_loginids => {return ($disabled_client->loginid)});
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('NewAccountLimitReached', 'correct error code.')
            ->error_message_is('You have created all accounts available to you.', 'It should return expected error message');
        $mock_user->unmock_all;
    };

    subtest 'Create new account maltainvest with manual tin approval' => sub {
        my $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer::get_random_email_address(),
                password       => BOM::User::Password::hashpw('Abcd33!@'),
                email_verified => 1,
                residence      => 'de',
            },
            [{
                    name        => 'CR',
                    broker_code => 'CR',
                },
            ]);

        my $params = {
            language => 'EN',
            source   => $app_id,
            country  => 'ru',
            args     => BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1),
            token    => $customer->get_client_token('CR'),
        };

        $params->{args}->{accept_risk} = 1;
        @{$params->{args}}{keys %$client_details} = values %$client_details;
        $params->{args}->{tax_residence} = 'de,nl';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error if missing any details')
            ->error_details_is({missing => ["tax_identification_number"]});

        my $client = $customer->get_client_object('CR');
        $client->tin_approved_time(Date::Utility->new()->datetime_yyyymmdd_hhmmss);
        $client->save;

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv Investments (Europe) Limited',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} }, 'maltainvest', 'Account is created successfully with manual tin approval');

        my $new_loginid = $rpc_ct->result->{client_id};

        $client = BOM::User::Client->new({loginid => $new_loginid});

        ok defined $client->tin_approved_time, 'tin_approved_time is copied from previous account';

    };

    subtest 'Create new account maltainvest giving tax_identification_number with already approved tin' => sub {
        my $customer = BOM::Test::Customer->create({
                email                    => BOM::Test::Customer::get_random_email_address(),
                password                 => BOM::User::Password::hashpw('Abcd33!@'),
                email_verified           => 1,
                residence                => 'de',
                secret_answer            => BOM::User::Utility::encrypt_secret_answer('mysecretanswer'),
                non_pep_declaration_time => '2020-01-02',
                fatca_declaration_time   => '2020-01-02',
                tin_approved_time        => Date::Utility->new()->datetime_yyyymmdd_hhmmss,
            },
            [{
                    name        => 'CR',
                    broker_code => 'CR',
                },
            ]);

        my $params = {
            language => 'EN',
            source   => $app_id,
            country  => 'ru',
            args     => BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1),
            token    => $customer->get_client_token('CR'),
        };

        $params->{args}->{accept_risk} = 1;
        @{$params->{args}}{keys %$client_details} = values %$client_details;
        $params->{args}->{tax_residence}             = 'de,nl';
        $params->{args}->{tax_identification_number} = '111222';

        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error->result_value_is(
            sub { shift->{landing_company} },
            'Deriv Investments (Europe) Limited',
            'It should return new account data'
        )->result_value_is(sub { shift->{landing_company_shortcode} },
            'maltainvest', 'Account is created successfully with existing tax_identification_number and manual tin approval');

        my $client = BOM::User::Client->new({loginid => $customer->get_client_loginid('CR')});
        ok !$client->tin_approved_time, 'tin_approved_time is removed if tax_idenitification_number is given';

        my $new_loginid = $rpc_ct->result->{client_id};

        my $cl = BOM::User::Client->new({loginid => $new_loginid});
        ok !defined $cl->tin_approved_time, 'tin_approved_time is not copied from previous account';

    };

    my $client_cr1;
    subtest 'Init CR CR' => sub {
        lives_ok {
            $customer = BOM::Test::Customer->create({
                    email                    => BOM::Test::Customer::get_random_email_address(),
                    password                 => BOM::User::Password::hashpw('Abcd33!@'),
                    email_verified           => 1,
                    residence                => 'za',
                    secret_answer            => BOM::User::Utility::encrypt_secret_answer('mysecretanswer'),
                    non_pep_declaration_time => '2020-01-02',
                    fatca_declaration_time   => '2020-01-02',
                },
                [{
                        name        => 'VRTC',
                        broker_code => 'VRTC',
                    },
                    {
                        name        => 'CR',
                        broker_code => 'CR',
                    },
                ]);

            $client_cr1 = $customer->get_client_object('CR');
            $client_cr1->status->set('age_verification', 'system', 'Age verified client');
            $client_cr1->save;
        }
        'Initial users and clients';
    };

    subtest 'Create new account maltainvest from CR' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $customer->get_client_token('CR');
        $params->{args}->{residence}   = 'za';
        $params->{args}->{citizen}     = 'za';
        delete $params->{args}->{non_pep_declaration};
        delete $params->{args}->{fatca_declaration};

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';

        my $result = $rpc_ct->call_ok($method, $params)->result;
        is $result->{error}->{code}, undef, 'Allow to open new account';

        my $new_loginid = $result->{client_id};
        my $token_db    = BOM::Database::Model::AccessToken->new();
        my $tokens      = $token_db->get_all_tokens_by_loginid($new_loginid);
        is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");

        my $auth_token_mf = BOM::Platform::Token::API->new->create_token($new_loginid, 'test token');

        # make sure data is same, as in first account, regardless of what we have provided
        my $cl = BOM::User::Client->new({loginid => $new_loginid});
        is $client_cr1->$_, $cl->$_, "$_ is correct on created account" for qw/first_name last_name residence address_city phone date_of_birth/;

        $result = $rpc_ct->call_ok('get_settings', {token => $auth_token_mf})->result;
        is($result->{tax_residence}, 'de,nl', ' client has tax residence set');
        $result = $rpc_ct->call_ok('get_financial_assessment', {token => $auth_token_mf})->result;
        isnt(keys %$result, 0, 'MF client has financial assessment set');

        ok $emitted{"signup_$new_loginid"}, "signup event emitted";
        ok $cl->status->age_verification,   'age verification synced between CR and MF.';
        ok $cl->non_pep_declaration_time,   'non_pep_declaration_time is auto-initialized with no non_pep_declaration in args';
        cmp_ok $cl->non_pep_declaration_time, 'ne', '2020-01-02T00:00:00', 'non_pep declaration time is different from MLT account';
        ok $cl->fatca_declaration_time, 'fatca_declaration_time is auto-initialized with no fatca_declaration in args';
        ok $cl->fatca_declaration,      'fatca_declaration is auto-initialized with no fatca_declaration in args';
        cmp_ok $cl->fatca_declaration_time, 'ne', '2020-01-02T00:00:00', 'fatca declaration time is different from MLT account';
    };

    subtest 'Check tax information and account opening reason is synchronize to CR from MF new account' => sub {
        my $customer = BOM::Test::Customer->create({
                email                     => BOM::Test::Customer::get_random_email_address(),
                password                  => BOM::User::Password::hashpw('Abcd33!@'),
                email_verified            => 1,
                residence                 => 'za',
                tax_residence             => 'ag',
                tax_identification_number => '1234567891',
                account_opening_reason    => 'Speculative',
                secret_answer             => BOM::User::Utility::encrypt_secret_answer('mysecretanswer'),
            },
            [{
                    name        => 'CR',
                    broker_code => 'CR',
                },
            ]);

        my @hash_array = ({
                field_name => "tax_residence",
                value      => "agd",
            },
            {
                field_name => "tax_identification_number",
                value      => "12345678918",
            },
            {
                field_name => "account_opening_reason",
                value      => "Income Earning",
            });

        $params->{token}                             = $customer->get_client_token('CR');
        $params->{args}->{residence}                 = 'za';
        $params->{args}->{citizen}                   = 'za';
        $params->{args}->{tax_residence}             = $hash_array[0]->{value};
        $params->{args}->{tax_identification_number} = $hash_array[1]->{value};
        $params->{args}->{account_opening_reason}    = $hash_array[2]->{value};
        delete $params->{args}->{non_pep_declaration};
        delete $params->{args}->{fatca_declaration};

        my $result = $rpc_ct->call_ok($method, $params)->result;
        is $result->{error}->{code}, undef, 'Allow to open new account';

        my $new_loginid = $result->{client_id};
        my $token_db    = BOM::Database::Model::AccessToken->new();
        my $tokens      = $token_db->get_all_tokens_by_loginid($new_loginid);
        is($tokens->[0]{info}, "App ID: $app_id", "token's app_id is correct");

        my $auth_token_mf = BOM::Platform::Token::API->new->create_token($new_loginid, 'test token');

        my $result_mf = $rpc_ct->call_ok('get_settings', {token => $auth_token_mf})->result;
        my $result_cr = $rpc_ct->call_ok('get_settings', {token => $customer->get_client_token('CR')})->result;

        foreach my $hash (@hash_array) {
            is($result_mf->{$hash->{field_name}}, $hash->{value}, "MF client has $hash->{field_name} set as $hash->{value}");
            is($result_cr->{$hash->{field_name}}, $hash->{value}, "CR client has $hash->{field_name} set as $hash->{value}");
        }
    };

    subtest 'Create a new account maltainvest from a virtual account' => sub {
        #create a virtual de client
        my $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer::get_random_email_address(),
                password       => BOM::User::Password::hashpw('Abcd33!@'),
                email_verified => 1,
                residence      => 'de',
            },
            [{
                    name        => 'VRTC',
                    broker_code => 'VRTC',
                },
            ]);

        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $customer->get_client_token('VRTC');
        $params->{args}->{residence}   = 'de';
        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';

        my $result = $rpc_ct->call_ok($method, $params)->result;
        ok $result->{client_id}, "Create an MF account from virtual account";

        ok $emitted{'signup_' . $result->{client_id}}, "signup event emitted";

        #create a virtual de client
        $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer::get_random_email_address(),
                password       => BOM::User::Password::hashpw('Abcd33!@'),
                email_verified => 1,
                residence      => 'de',
            },
            [{
                    name        => 'VRTC',
                    broker_code => 'VRTC',
                },
            ]);

        $params->{token} = $customer->get_client_token('VRTC');
        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_ . rand(9)) =~ s/_// for qw/first_name last_name residence address_city/;
        $params->{args}->{phone}           = '+62 21 12345999';
        $params->{args}->{date_of_birth}   = '1990-09-09';
        $params->{args}->{residence}       = 'de';
        $params->{args}->{secret_answer}   = 'test';
        $params->{args}->{secret_question} = 'test';

        $result = $rpc_ct->call_ok($method, $params)->result;
        ok $result->{client_id}, "Germany users can create MF account from the virtual account";

        ok $emitted{'signup_' . $result->{client_id}}, "signup event emitted";

        my $cl = BOM::User::Client->new({loginid => $result->{client_id}});
        ok $cl->non_pep_declaration_time,
            'non_pep_declaration_time is auto-initialized with no non_pep_declaration in args (test create_account call)';
        ok $cl->fatca_declaration_time, 'fatca_declaration_time is auto-initialized with no fatca_declaration in args (test create_account call)';
        ok $cl->fatca_declaration,      'fatca_declaration is auto-initialized with no fatca_declaration in args (test create_account call)';
    };

    my $auth_token;
    subtest 'Create new account maltainvest without MLT' => sub {
        my $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer::get_random_email_address(),
                password       => BOM::User::Password::hashpw('Abcd33!@'),
                email_verified => 1,
                residence      => 'at',
            },
            [{
                    name        => 'VRTC',
                    broker_code => 'VRTC',
                },
            ]);

        $params->{token} = $customer->get_client_token('VRTC');
        ($params->{args}->{$_} = $_ . rand(9)) =~ s/_// for qw/first_name last_name residence address_city/;
        $params->{args}->{phone}           = '+62 21 12098999';
        $params->{args}->{date_of_birth}   = '1990-09-09';
        $params->{args}->{residence}       = 'at';
        $params->{address_state}           = 'Salzburg';
        $params->{args}->{secret_answer}   = 'test';
        $params->{args}->{secret_question} = 'test';

        my $result = $rpc_ct->call_ok($method, $params)->has_no_error->result;
        ok $result->{client_id}, "Austrian users can create MF account from the virtual account";

        $auth_token = BOM::Platform::Token::API->new->create_token($result->{client_id}, 'test token');
    };

    subtest 'Create new gaming account from MF - not available' => sub {
        $params->{args}->{accept_risk} = 1;
        $params->{token}               = $auth_token;
        $params->{args}->{residence}   = 'at';
        $method                        = 'new_account_real';
        mailbox_clear();

        # call with totally random values - our client still should have correct one
        ($params->{args}->{$_} = $_) =~ s/_// for qw/first_name last_name address_city/;
        $params->{args}->{phone}         = '+62 21 12345678';
        $params->{args}->{date_of_birth} = '1990-09-09';
        $params->{args}->{residence}     = 'at';
        # We have to delete these fields here as our test helper function creates clients with different fields than what is declared above in this file. Should change this.
        delete $params->{args}->{secret_question};
        delete $params->{args}->{secret_answer};

        $rpc_ct->call_ok($method, $params)->has_error->error_code_is('InvalidAccount')->error_message_is('Sorry, account opening is unavailable.');
    };
};

$method = 'new_account_real';

subtest 'Duplicate accounts are not created in race condition' => sub {
    my $params = {};

    $email                               = BOM::Test::Customer::get_random_email_address();
    $params->{args}->{client_password}   = 'Abcd333@!';
    $params->{args}->{residence}         = 'id';
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('If verification code is ok - account created successfully')
        ->result_value_is(sub { shift->{currency} },      'USD',  'It should return new account data')
        ->result_value_is(sub { shift->{currency_type} }, 'fiat', 'It should return new account data')
        ->result_value_is(sub { ceil shift->{balance} },  10000,  'It should return new account data');

    my $client_cr = {
        first_name    => 'James' . rand(999),
        last_name     => 'Brown' . rand(999),
        date_of_birth => '1960-01-02',
        phone         => sprintf("+792720756%02d", rand(99)),
    };
    @{$params->{args}}{keys %$client_cr} = values %$client_cr;
    $params->{token} = $rpc_ct->result->{oauth_token};
    $params->{args}->{currency} = 'USD';

    my $mocked_system = Test::MockModule->new('BOM::Config');
    $mocked_system->mock('on_production', sub { 1 });
    my $mocked_platform_redis = Test::MockModule->new('BOM::Platform::Redis');
    $mocked_platform_redis->mock(
        'acquire_lock',
        sub {
            return undef;
        });

    my $result = $rpc_ct->call_ok($method, $params)->{result};
    undef $mocked_platform_redis;

    is $result->{error}{code}, 'RateLimitExceeded', 'Account creation face error RateLimitExceeded in race condition';
};

$method = 'new_account_wallet';
$params = {
    language => 'EN',
    source   => $app_id,
    args     => {
        last_name        => 'Test' . rand(999),
        first_name       => 'Test1' . rand(999),
        date_of_birth    => '1987-09-04',
        address_line_1   => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01',
        address_city     => 'Samara',
        address_state    => 'Papua',
        address_postcode => '112233',
    },
};

subtest $method => sub {
    my $customer;

    subtest 'Initialization' => sub {
        lives_ok {
            $customer = BOM::Test::Customer->create({
                    email     => BOM::Test::Customer::get_random_email_address(),
                    password  => BOM::User::Password::hashpw('Abcd3s3!@'),
                    residence => 'id',
                    citizen   => 'id',
                },
                [{
                        name        => 'VRTC',
                        broker_code => 'VRTC',
                    },
                ]);
        }
        'Initial users and clients';
    };

    my $mock_business_countries = Test::MockModule->new('Business::Config::Country');
    my $mock_countries          = Test::MockModule->new('Brands::Countries');

    subtest 'Create new CRW wallet real' => sub {
        $emit_data = {};
        $params->{token} = $customer->get_client_token('VRTC');

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $customer->get_user_id(),
            attributes => {email_verified => 1},
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        my $app_config = BOM::Config::Runtime->instance->app_config;
        ok $app_config->system->suspend->wallets, 'wallets are suspended';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied',
            'It should return error code if wallet is unavailable in country of residence.')
            ->error_message_is('Wallet account creation is currently suspended.', 'Error message about service unavailability.');

        $app_config->system->suspend->wallets(0);

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        is_deeply $result->{error},
            {
            code              => 'InvalidRequestParams',
            message_to_client => 'Invalid request parameters.',
            details           => {field => 'currency'}
            },
            'Correct error for missing currency.';

        $params->{args}->{currency} = 'DUMMY';
        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        is_deeply $result->{error},
            {
            code              => 'InvalidRequestParams',
            message_to_client => 'Invalid request parameters.',
            details           => {field => 'currency'}
            },
            'Correct error for invalid currency.';

        $params->{args}->{currency} = 'USD';

        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;

        is_deeply $result->{error},
            {
            code              => 'InvalidRequestParams',
            message_to_client => 'Invalid request parameters.',
            details           => {field => 'account_type'}
            },
            'Correct error for invalid currency.';

        $params->{args}->{account_type} = 'doughflow';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidAccountRegion',
            'It should return error code if wallet is unavailable in country of residence.')
            ->error_message_is('Sorry, account opening is unavailable in your region.', 'Error message about service unavailability.');

        $mock_countries->redefine(wallet_companies_for_country => ['svg']);
        $mock_business_countries->redefine(wallet_companies => ['svg']);
        $params->{args}->{currency} = 'USD';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied',
            'It should return error code if no wallets were found in the account.')
            ->error_message_is('Permission denied.', 'Error message about service unavailability.');

        $customer->create_client(
            'VRW',
            {
                broker_code => 'VRW',
                citizen     => 'id',
                residence   => 'id'
            });
        $params->{token} = $customer->get_client_token('VRW');

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_no_error('If passed argumets are ok a new real wallet will be created successfully');
        $rpc_ct->result_value_is(sub { shift->{landing_company_shortcode} }, 'svg', 'It should return wallet landing company');

        my $new_loginid = $rpc_ct->result->{client_id};
        ok $new_loginid =~ /^CRW\d+/, 'new CRW loginid';
        is $emit_data->{properties}->{type},    'wallet', 'type=wallet';
        is $emit_data->{properties}->{subtype}, 'real',   'subtype=real';

        my $wallet_client = BOM::User::Client->get_client_instance($new_loginid);
        isa_ok($wallet_client, 'BOM::User::Wallet', 'get_client_instance returns instance of wallet');
        ok($wallet_client->is_wallet,  'wallet client is_wallet is true');
        ok(!$wallet_client->can_trade, 'wallet client can_trade is false');
        is $wallet_client->residence, 'id', 'Residence is copied from the virtual account';

        ok $emitted{"signup_$new_loginid"}, "signup event emitted";

        $app_config->system->suspend->wallets(1);
    };

    $mock_business_countries->unmock_all;
    $mock_countries->unmock_all;
};

$method = 'new_account_wallet';
$params = {
    language => 'EN',
    source   => $app_id,
    args     => {
        last_name        => 'Test' . rand(999),
        first_name       => 'Test1' . rand(999),
        date_of_birth    => '1987-09-04',
        address_line_1   => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01',
        address_city     => 'Samara',
        address_state    => 'Papua',
        address_postcode => '112233',
        residence        => 'de',
        salutation       => 'Mr.'
    },
};

subtest $method => sub {
    my ($customer);

    subtest 'Initialization' => sub {
        lives_ok {
            $customer = BOM::Test::Customer->create({
                    email     => BOM::Test::Customer::get_random_email_address(),
                    password  => BOM::User::Password::hashpw('Abcd3s3!@'),
                    residence => 'de',
                    citizen   => 'de',
                },
                [{
                        name        => 'VRTC',
                        broker_code => 'VRTC',
                    },
                ]);
        }
        'Initial users and clients';
    };

    my $mock_business_countries = Test::MockModule->new('Business::Config::Country');
    my $mock_countries          = Test::MockModule->new('Brands::Countries');

    subtest 'Create new MFW wallet real - EU country' => sub {
        $emit_data = {};
        $params->{token} = $customer->get_client_token('VRTC');

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $customer->get_user_id(),
            attributes => {email_verified => 1},
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        my $app_config = BOM::Config::Runtime->instance->app_config;
        ok $app_config->system->suspend->wallets, 'wallets are suspended';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied',
            'It should return error code if wallet is unavailable in country of residence.')
            ->error_message_is('Wallet account creation is currently suspended.', 'Error message about service unavailability.');

        $app_config->system->suspend->wallets(0);

        my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        is_deeply $result->{error},
            {
            code              => 'InvalidRequestParams',
            message_to_client => 'Invalid request parameters.',
            details           => {field => 'currency'}
            },
            'Correct error for missing currency.';

        $params->{args}->{currency} = 'DUMMY';
        $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->has_error->result;
        is_deeply $result->{error},
            {
            code              => 'InvalidRequestParams',
            message_to_client => 'Invalid request parameters.',
            details           => {field => 'currency'}
            },
            'Correct error for invalid currency.';

        $params->{args}->{currency} = 'USD';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidRequestParams', 'It should return error code if missing any details')
            ->error_message_is('Invalid request parameters.', 'It should return error message if missing any details')
            ->error_details_is({field => "account_type"});

        $params->{args}->{account_type} = 'doughflow';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidAccountRegion',
            'It should return error code if wallet is unavailable in country of residence.')
            ->error_message_is('Sorry, account opening is unavailable in your region.', 'Error message about service unavailability.');

        $mock_countries->redefine(wallet_companies_for_country => ['maltainvest']);
        $mock_business_countries->redefine(wallet_companies => ['maltainvest']);
        $params->{args}->{landing_company_short} = 'maltainvest';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InvalidState',
            'correct error code if address state doesnt match the country of residence')
            ->error_message_is('Sorry, the provided state is not valid for your country of residence.', 'Invalid state error message');

        $params->{args}->{address_state} = 'HH';

        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PermissionDenied',
            'It should return error code if no wallets were found in the account.')
            ->error_message_is('Permission denied.', 'Error message about service unavailability.');

        $customer->create_client(
            'VRW',
            {
                broker_code => 'VRW',
                citizen     => 'de',
                residence   => 'de'
            });

        $params->{token} = $customer->get_client_token('VRW');
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('InsufficientAccountDetails', 'It should return error code if missing any details')
            ->error_message_is('Please provide complete details for your account.', 'It should return error message if missing any details')
            ->error_details_is({missing => ["tax_residence", "tax_identification_number", "account_opening_reason"]});

        $params->{args}->{tax_residence}             = 'de';
        $params->{args}->{tax_identification_number} = 'MRTSVT79M29F8P9P';
        $params->{args}->{financial_assessment}      = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_no_error('If passed argumets are ok a new real wallet will be created successfully');
        $rpc_ct->result_value_is(sub { shift->{landing_company_shortcode} }, 'maltainvest', 'It should return wallet landing company');

        my $new_loginid = $rpc_ct->result->{client_id};

        ok $new_loginid =~ /^MFW\d+/, 'new MFW loginid';
        is $emit_data->{properties}->{type},    'wallet', 'type=wallet';
        is $emit_data->{properties}->{subtype}, 'real',   'subtype=real';

        my $wallet_client = BOM::User::Client->get_client_instance($new_loginid);
        isa_ok($wallet_client, 'BOM::User::Wallet', 'get_client_instance returns instance of wallet');
        ok($wallet_client->is_wallet,  'wallet client is_wallet is true');
        ok(!$wallet_client->can_trade, 'wallet client can_trade is false');
        is $wallet_client->residence, 'de', 'Residence is copied from the virtual account';

        is($wallet_client->account_type, 'doughflow', 'Account type field is decommisioned, it will be renamed to account_type');
        ok $emitted{"signup_$new_loginid"}, "signup event emitted";

        $app_config->system->suspend->wallets(1);
    };

    $mock_business_countries->unmock_all;
    $mock_countries->unmock_all;
};

$method = 'new_account_wallet';
$params = {
    language => 'EN',
    source   => $app_id,
    args     => {
        last_name        => 'Test' . rand(999),
        first_name       => 'Test1' . rand(999),
        date_of_birth    => '1987-09-04',
        address_line_1   => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01',
        address_city     => 'Samara',
        address_state    => 'Papua',
        address_postcode => '112233',
    },
};

subtest $method => sub {
    my $customer;

    subtest 'Initialization' => sub {
        lives_ok {
            $customer = BOM::Test::Customer->create({
                    email          => BOM::Test::Customer::get_random_email_address(),
                    password       => BOM::User::Password::hashpw('Abcd3s3!@'),
                    email_verified => 1,
                    residence      => 'id',
                    citizen        => 'id',
                },
                [{
                        name        => 'VRTC',
                        broker_code => 'VRTC',
                    },
                ]);

        }
        'Initial users and clients';
    };
};

$method = 'new_account_wallet';
$params = {
    language => 'EN',
    source   => $app_id,
    args     => {
        last_name        => 'Test' . rand(999),
        first_name       => 'Test1' . rand(999),
        date_of_birth    => '1977-01-04',
        address_line_1   => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01',
        address_city     => 'Bloemfontein',
        address_state    => 'Free State',
        address_postcode => '112233',
        residence        => 'za',
        salutation       => 'Mr.',
        citizen          => 'za'
    },
};

subtest $method => sub {
    my $customer;

    subtest 'Initialization' => sub {
        lives_ok {
            $customer = BOM::Test::Customer->create({
                    email          => BOM::Test::Customer::get_random_email_address(),
                    password       => BOM::User::Password::hashpw('Abcd3s3!@'),
                    email_verified => 1,
                    residence      => 'za',
                    citizen        => 'za',
                },
                [{
                        name        => 'VRTC',
                        broker_code => 'VRTC',
                    },
                ]);
        }
        'Initial users and clients';
    };

    my $mock_business_countries = Test::MockModule->new('Business::Config::Country');
    my $mock_countries          = Test::MockModule->new('Brands::Countries');

    subtest 'Create new MFW/CRW wallet real - Diel country' => sub {
        $emit_data = {};
        $params->{token} = $customer->get_client_token('VRTC');
        my $app_config = BOM::Config::Runtime->instance->app_config;

        my $user_data = BOM::Service::user(
            context    => BOM::Test::Customer::get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $customer->get_user_id(),
            attributes => {email_verified => 1},
        );
        is $user_data->{status}, 'ok', 'user service call succeeded';

        $app_config->system->suspend->wallets(0);

        $params->{args}->{currency}     = 'USD';
        $params->{args}->{citizen}      = 'za';
        $params->{args}->{account_type} = 'doughflow';
        $mock_countries->redefine(wallet_companies_for_country => ['maltainvest', 'svg']);
        $mock_business_countries->redefine(wallet_companies => ['maltainvest', 'svg']);
        $params->{args}->{landing_company_short} = 'maltainvest';

        $customer->create_client(
            'VRW',
            {
                broker_code => 'VRW',
                citizen     => 'za',
                residence   => 'za'
            });

        $params->{token}                             = $customer->get_client_token('VRW');
        $params->{args}->{tax_residence}             = 'de';
        $params->{args}->{tax_identification_number} = 'MRTSVT79M29F8P9P';
        $params->{args}->{financial_assessment}      = BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1);

        ## Wallet Created
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_no_error('If passed argumets are ok a new real MF wallet will be created successfully')
            ->result_value_is(sub { shift->{landing_company_shortcode} }, 'maltainvest', 'It should return wallet landing company')
            ->result_value_is(sub { shift->{currency} },                  'USD',         'It should return wallet currency')
            ->result_value_is(sub { shift->{currency_type} },             'fiat',        'It should return wallet currency type');

        ## Same wallet duplicate error
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('DuplicateWallet', 'It should return error code when the same MFW is added')
            ->error_message_is('Sorry, a wallet already exists with those details.', 'It should return error message for duplicates');

        ## Same wallet duplicate error with different currency
        $params->{args}->{currency} = 'EUR';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('CurrencyTypeNotAllowed',
            'It should return error code when the same MFW is added with different currency')
            ->error_message_is('Please note that you are limited to one fiat currency account.', 'It should return error message for duplicates');

        delete $params->{args}->{financial_assessment};

        $params->{args}->{landing_company_short} = 'svg';
        $params->{args}->{currency}              = 'USD';
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_no_error('If passed argumets are ok a new real CR wallet will be created successfully')
            ->result_value_is(sub { shift->{landing_company_shortcode} }, 'svg',  'It should return wallet landing company')
            ->result_value_is(sub { shift->{currency} },                  'USD',  'It should return wallet currency')
            ->result_value_is(sub { shift->{currency_type} },             'fiat', 'It should return wallet currency type');

        ## Same wallet duplicate error
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('DuplicateWallet', 'It should return error code when the same CRW is addeds')
            ->error_message_is('Sorry, a wallet already exists with those details.', 'It should return error message for duplicates');

        $app_config->system->suspend->wallets(1);
    };

    $mock_business_countries->unmock_all;
    $mock_countries->unmock_all;
};

$method = 'new_account_wallet';
$params = {
    language => 'EN',
    source   => $app_id,
    args     => {
        last_name        => 'Test_first_name_FA_01',
        first_name       => 'Test_last_name_FA_01',
        date_of_birth    => '1987-09-04',
        address_line_1   => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01',
        address_city     => 'Samara',
        address_state    => 'Papua',
        address_postcode => '112233',
    },
};

subtest $method => sub {
    my ($customer, $client, $vr_client, $auth_token);
    my $password = 'Abcd3s3!@';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    $email = 'new_email+fa@binary.com';

    $customer = BOM::Test::Customer->create({
            email          => $email,
            password       => $hash_pwd,
            email_verified => 1,
        },
        [{
                name        => 'VRTC',
                broker_code => 'VRTC',
                citizen     => 'id',
                residence   => 'id'
            },
            {
                name        => 'VRW',
                broker_code => 'VRW',
                citizen     => 'id',
                residence   => 'id'
            },
        ]);
    $client     = $customer->get_client_object('VRTC');
    $auth_token = $customer->get_client_token('VRTC');

    my $mock_business_countries = Test::MockModule->new('Business::Config::Country');
    my $mock_countries          = Test::MockModule->new('Brands::Countries');

    subtest 'Check Create Wallet will copy the FA if it exist' => sub {
        $emit_data = {};
        $params->{token} = $auth_token;
        my $app_config = BOM::Config::Runtime->instance->app_config;
        $app_config->system->suspend->wallets(0);
        $params->{args}->{currency}     = 'USD';
        $params->{args}->{account_type} = 'doughflow';
        $mock_countries->redefine(wallet_companies_for_country => ['svg']);
        $mock_business_countries->redefine(wallet_companies => ['svg']);

        $vr_client       = $customer->get_client_object('VRW');
        $auth_token      = $customer->get_client_token('VRW');
        $params->{token} = $auth_token;
        $rpc_ct->call_ok($method, $params)
            ->has_no_system_error->has_no_error('If passed argumets are ok a new real wallet will be created successfully');

        my $new_loginid = $rpc_ct->result->{client_id};

        my $wallet_client = BOM::User::Client->get_client_instance($new_loginid);

        # Set financial assessment for default client before making a new account to check if new account inherits the financial assessment data
        my $data = BOM::Test::Helper::FinancialAssessment::get_fulfilled_hash();
        $wallet_client->financial_assessment({
            data => encode_json_utf8($data),
        });
        $wallet_client->save();

        $auth_token = BOM::Platform::Token::API->new->create_token($wallet_client->loginid, 'test token');
        $params->{token} = $auth_token;

        $params->{args}->{currency}     = 'BTC';
        $params->{args}->{account_type} = 'crypto';
        $rpc_ct->call_ok($method, $params)->has_no_system_error->has_no_error('create second crypto currency account')
            ->result_value_is(sub { shift->{currency} },      'BTC',    'crypto account currency is BTC')
            ->result_value_is(sub { shift->{currency_type} }, 'crypto', 'crypto account currency type is crypto');

        my $cl_ltc = BOM::User::Client->new({loginid => $rpc_ct->result->{client_id}});
        ok(defined($cl_ltc->financial_assessment()), 'new client has financial assessment if previous client has FA as well');

        $app_config->system->suspend->wallets(1);
    };

    $mock_countries->unmock_all;
    $mock_business_countries->unmock_all;
};

$params = {
    language => 'EN',
    source   => $app_id,
    args     => {
        last_name        => 'Test' . rand(999),
        first_name       => 'Test1' . rand(999),
        date_of_birth    => '1987-09-04',
        address_line_1   => 'Sovetskaya street bluewater’s lane# 6 sector AB/p01',
        address_city     => 'Samara',
        address_state    => 'Papua',
        address_postcode => '112233',
    },
};
subtest 'Empty phone number' => sub {
    my $email = 'empty+phone1241241@asdf.com';
    $params->{country}                   = 'br';
    $params->{args}->{residence}         = 'br';
    $params->{args}->{address_state}     = 'SP';
    $params->{args}->{client_password}   = '123Abas!';
    $params->{args}->{phone}             = '';
    $params->{args}->{first_name}        = 'i dont have';
    $params->{args}->{last_name}         = 'a phone number';
    $params->{args}->{date_of_birth}     = '1999-01-01';
    $params->{args}->{email}             = $email;
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    delete $params->{token};

    $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('vr account created successfully');
    my $vr_loginid = $rpc_ct->result->{client_id};

    $params->{token} = BOM::Platform::Token::API->new->create_token($vr_loginid, 'test token');
    $rpc_ct->call_ok('new_account_real', $params)->has_no_system_error->has_no_error('real account created successfully');

    my $real_loginid = $rpc_ct->result->{client_id};
    my $client       = BOM::User::Client->new({loginid => $real_loginid});
    is $client->phone, '', 'No phone set';
};

subtest 'Affiliate link' => sub {
    subtest 'Spain' => sub {
        my $email = 'afflink+sp@asdf.com';
        $params->{country}                   = 'es';
        $params->{args}->{residence}         = 'es';
        $params->{args}->{address_state}     = 'SP';
        $params->{args}->{client_password}   = '123Abas!';
        $params->{args}->{first_name}        = 'i came from';
        $params->{args}->{last_name}         = 'some es affiliate';
        $params->{args}->{date_of_birth}     = '1999-01-01';
        $params->{args}->{email}             = $email;
        $params->{args}->{affiliate_token}   = 'thetoken';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        delete $params->{token};

        $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('vr account created successfully');
        my $vr_loginid = $rpc_ct->result->{client_id};

        my $client = BOM::User::Client->new({loginid => $vr_loginid});
        is $client->myaffiliates_token, '', 'No token set for es account';
    };

    subtest 'Portugal' => sub {
        my $email = 'afflink+pt@asdf.com';
        $params->{country}                   = 'pt';
        $params->{args}->{residence}         = 'pt';
        $params->{args}->{address_state}     = 'SP';
        $params->{args}->{client_password}   = '123Abas!';
        $params->{args}->{first_name}        = 'i came from';
        $params->{args}->{last_name}         = 'some pt affiliate';
        $params->{args}->{date_of_birth}     = '1999-01-01';
        $params->{args}->{email}             = $email;
        $params->{args}->{affiliate_token}   = 'thetoken';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        delete $params->{token};

        $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('vr account created successfully');
        my $vr_loginid = $rpc_ct->result->{client_id};

        my $client = BOM::User::Client->new({loginid => $vr_loginid});
        is $client->myaffiliates_token, '', 'No token set for pt account';
    };

    subtest 'Argentina' => sub {
        my $email = 'afflink+ar@asdf.com';
        $params->{country}                   = 'ar';
        $params->{args}->{residence}         = 'ar';
        $params->{args}->{address_state}     = 'SP';
        $params->{args}->{client_password}   = '123Abas!';
        $params->{args}->{first_name}        = 'i came from';
        $params->{args}->{last_name}         = 'some ar affiliate';
        $params->{args}->{date_of_birth}     = '1999-01-01';
        $params->{args}->{email}             = $email;
        $params->{args}->{affiliate_token}   = 'thetoken';
        $params->{args}->{verification_code} = BOM::Platform::Token->new(
            email       => $email,
            created_for => 'account_opening'
        )->token;

        delete $params->{token};

        $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('vr account created successfully');
        my $vr_loginid = $rpc_ct->result->{client_id};

        my $client = BOM::User::Client->new({loginid => $vr_loginid});
        is $client->myaffiliates_token, 'thetoken', 'Token set for ar account';
    };
};

subtest 'Unknown country' => sub {
    my $email = 'country+xx@asdf.com';
    $params->{country}                   = 'xx';
    $params->{args}->{residence}         = 'xx';
    $params->{args}->{address_state}     = 'SP';
    $params->{args}->{client_password}   = '123Abas!';
    $params->{args}->{first_name}        = 'i came from';
    $params->{args}->{last_name}         = 'some xx country';
    $params->{args}->{date_of_birth}     = '1999-01-01';
    $params->{args}->{email}             = $email;
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    delete $params->{token};

    $rpc_ct->call_ok('new_account_virtual', $params)
        ->has_no_system_error->has_error->error_code_is('invalid residence', 'xx is not a well known country');
};

subtest 'Missing phone number' => sub {
    my $email = 'missing+phone1241241@asdf.com';
    $params->{country}                 = 'br';
    $params->{args}->{residence}       = 'br';
    $params->{args}->{client_password} = '123Abas!';
    $params->{args}->{first_name}      = 'i miss';
    $params->{args}->{last_name}       = 'my phone number';
    $params->{args}->{date_of_birth}   = '1999-01-02';
    $params->{args}->{email}           = $email;
    delete $params->{args}->{phone};
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    delete $params->{token};

    $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('vr account created successfully');
    my $vr_loginid = $rpc_ct->result->{client_id};

    $params->{token} = BOM::Platform::Token::API->new->create_token($vr_loginid, 'test token');
    $rpc_ct->call_ok('new_account_real', $params)->has_no_system_error->has_no_error('real account created successfully');

    my $real_loginid = $rpc_ct->result->{client_id};
    my $client       = BOM::User::Client->new({loginid => $real_loginid});
    is $client->phone, '', 'No phone set';
};

subtest 'Repeating phone number' => sub {
    my $email = 'repeating+phone@asdf.com';
    $params->{country}                   = 'br';
    $params->{args}->{residence}         = 'br';
    $params->{args}->{client_password}   = '123Abas!';
    $params->{args}->{first_name}        = 'i repeat';
    $params->{args}->{last_name}         = 'my phone number';
    $params->{args}->{date_of_birth}     = '1999-01-02';
    $params->{args}->{email}             = $email;
    $params->{args}->{phone}             = '111111111';
    $params->{args}->{verification_code} = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_opening'
    )->token;

    delete $params->{token};

    $rpc_ct->call_ok('new_account_virtual', $params)->has_no_system_error->has_no_error('vr account created successfully');
    my $vr_loginid = $rpc_ct->result->{client_id};

    $params->{token} = BOM::Platform::Token::API->new->create_token($vr_loginid, 'test token');
    $rpc_ct->call_ok('new_account_real', $params)->has_no_system_error->has_error->error_code_is('InvalidPhone', 'Repeating digits are not valid')
        ->error_message_is('Please enter a valid phone number, including the country code (e.g. +15417541234).',
        "Invalid phone number provided (repeated digits)");
};

subtest 'Forbidden postcodes' => sub {
    my $idauth_mock = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
    $idauth_mock->mock(
        'run_validation',
        sub {
            return 1;
        });

    my $hash_pwd = BOM::User::Password::hashpw('Abcd33!@');
    my $customer = BOM::Test::Customer->create({
            email          => BOM::Test::Customer::get_random_email_address(),
            password       => $hash_pwd,
            email_verified => 1,
            residence      => 'gb',
        },
        [{
                name        => 'VRTC',
                broker_code => 'VRTC',
            },
        ]);

    $params->{country} = 'gb';
    $params->{args}    = {
        "residence"                 => 'gb',
        "first_name"                => 'mr family',
        "last_name"                 => 'man',
        "date_of_birth"             => '1999-01-02',
        "email"                     => $customer->get_email(),
        "phone"                     => '+15417541234',
        "salutation"                => 'hello',
        "citizen"                   => 'gb',
        "tax_residence"             => 'gb',
        "tax_identification_number" => 'E1241241',
        BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1)->%*
    };
    $params->{token} = BOM::Platform::Token::API->new->create_token($customer->get_client_loginid('VRTC'), 'test token');

    $params->{args}->{address_postcode} = 'JE2';
    $rpc_ct->call_ok('new_account_maltainvest', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidAccount', 'InvalidAccount (used to be Invalid Jersey postcode)');

    $params->{args}->{address_postcode} = 'EA1 C1A1';

    $rpc_ct->call_ok('new_account_maltainvest', $params)
        ->has_no_system_error->has_error->error_code_is('InvalidAccount', 'InvalidAccount (used to be a valid request)');

};

subtest 'Italian TIN test' => sub {
    subtest 'Old format' => sub {
        my $idauth_mock = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
        $idauth_mock->mock(
            'run_validation',
            sub {
                return 1;
            });

        my $hash_pwd = BOM::User::Password::hashpw('Alienbatata20');
        my $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer::get_random_email_address(),
                password       => $hash_pwd,
                email_verified => 1,
                residence      => 'it',
            },
            [{
                    name        => 'VRTC',
                    broker_code => 'VRTC',
                },
            ]);

        $params->{country}                 = 'it';
        $params->{args}->{residence}       = 'it';
        $params->{args}->{client_password} = $hash_pwd;
        $params->{args}->{subtype}         = 'real';
        $params->{args}->{first_name}      = 'Josue Lee';
        $params->{args}->{last_name}       = 'King';
        $params->{args}->{date_of_birth}   = '1989-09-01';
        $params->{args}->{email}           = $customer->get_email();
        $params->{args}->{phone}           = '+393678917832';
        $params->{args}->{salutation}      = 'Op';
        $params->{args}->{citizen}         = 'it';
        $params->{args}->{accept_risk}     = 1;
        $params->{token}                   = $customer->get_client_token('VRTC');

        $params->{args} = {
            $params->{args}->%*,
            BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1)->%*,
            'tax_residence'             => 'it',
            'tax_identification_number' => 'MRTSVT79M29F899P',
        };

        my $result =
            $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('it mf account created successfully')->result;
        ok $result->{client_id}, 'got a client id';
    };

    subtest 'New format' => sub {
        my $idauth_mock = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
        $idauth_mock->mock(
            'run_validation',
            sub {
                return 1;
            });

        my $hash_pwd = BOM::User::Password::hashpw('Alienbatata20');
        my $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer::get_random_email_address(),
                password       => $hash_pwd,
                email_verified => 1,
                residence      => 'it',
            },
            [{
                    name        => 'VRTC',
                    broker_code => 'VRTC',
                },
            ]);

        $params->{country}                 = 'it';
        $params->{args}->{residence}       = 'it';
        $params->{args}->{client_password} = $hash_pwd;
        $params->{args}->{subtype}         = 'real';
        $params->{args}->{first_name}      = 'Joseph Batata';
        $params->{args}->{last_name}       = 'Junior';
        $params->{args}->{date_of_birth}   = '1997-01-01';
        $params->{args}->{email}           = $customer->get_email();
        $params->{args}->{phone}           = '+393678916732';
        $params->{args}->{salutation}      = 'Hi';
        $params->{args}->{citizen}         = 'it';
        $params->{args}->{accept_risk}     = 1;
        $params->{token}                   = $customer->get_client_token('VRTC');

        $params->{args} = {
            $params->{args}->%*,
            BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1)->%*,
            'tax_residence'             => 'it',
            'tax_identification_number' => 'MRTSVT79M29F8P9P',
        };

        my $result =
            $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('it mf account created successfully')->result;
        ok $result->{client_id}, 'got a client id';
    };

    subtest 'TIN with wrong format' => sub {
        my $idauth_mock = Test::MockModule->new('BOM::Platform::Client::IDAuthentication');
        $idauth_mock->mock(
            'run_validation',
            sub {
                return 1;
            });

        my $hash_pwd = BOM::User::Password::hashpw('Allison90');
        my $customer = BOM::Test::Customer->create({
                email          => BOM::Test::Customer::get_random_email_address(),
                password       => $hash_pwd,
                email_verified => 1,
                residence      => 'it',
            },
            [{
                    name        => 'VRTC',
                    broker_code => 'VRTC',
                },
            ]);

        $params->{country}                 = 'it';
        $params->{args}->{residence}       = 'it';
        $params->{args}->{client_password} = $hash_pwd;
        $params->{args}->{subtype}         = 'real';
        $params->{args}->{first_name}      = 'Allison Laura';
        $params->{args}->{last_name}       = 'Sean';
        $params->{args}->{date_of_birth}   = '1997-01-01';
        $params->{args}->{email}           = $customer->get_email();
        $params->{args}->{phone}           = '+393678916702';
        $params->{args}->{salutation}      = 'Helloo';
        $params->{args}->{citizen}         = 'it';
        $params->{args}->{accept_risk}     = 1;
        $params->{token}                   = $customer->get_client_token('VRTC');

        $params->{args} = {
            $params->{args}->%*,
            BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1)->%*,
            'tax_identification_number' => 'MRTSVT79M29F8_9P',
            'account_opening_reason'    => 'Hedging',
        };

        my $result =
            $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('it mf account created successfully')->result;
        ok $result->{client_id}, 'got a client id';
    };
};

subtest 'MF under Duplicated account' => sub {
    my $hash_pwd = BOM::User::Password::hashpw('Abcd1234!!');
    my $customer = BOM::Test::Customer->create({
            email          => BOM::Test::Customer::get_random_email_address(),
            password       => $hash_pwd,
            email_verified => 1,
            residence      => 'it',
        },
        [{
                name        => 'VRTC',
                broker_code => 'VRTC',
            },
        ]);

    $params->{country}                 = 'it';
    $params->{args}->{residence}       = 'it';
    $params->{args}->{address_line_1}  = 'sus';
    $params->{args}->{address_city}    = 'sus';
    $params->{args}->{client_password} = $hash_pwd;
    $params->{args}->{subtype}         = 'real';
    $params->{args}->{first_name}      = 'Not her';
    $params->{args}->{last_name}       = 'not';
    $params->{args}->{date_of_birth}   = '1997-01-02';
    $params->{args}->{email}           = $customer->get_email();
    $params->{args}->{phone}           = '+393678916703';
    $params->{args}->{salutation}      = 'hey';
    $params->{args}->{citizen}         = 'it';
    $params->{args}->{accept_risk}     = 1;
    $params->{token}                   = $customer->get_client_token('VRTC');

    $params->{args} = {
        $params->{args}->%*,
        BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1)->%*,
        'tax_residence'             => 'it',
        'tax_identification_number' => 'MRTSVT79M29F8_9P',
    };

    my $result =
        $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('it mf account created successfully')->result;
    ok $result->{client_id}, 'got a client id';

    my $new_client = BOM::User::Client->new({loginid => $result->{client_id}});
    $new_client->status->set('duplicate_account', 'system', 'Duplicate account - currency change');

    $result = $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('it mf account created successfully')->result;
    ok $result->{client_id}, 'got a second id';
};

subtest 'MF under Duplicated account - DIEL country' => sub {
    my $hash_pwd = BOM::User::Password::hashpw('Abcd1234!!');
    my $customer = BOM::Test::Customer->create({
            email                     => BOM::Test::Customer::get_random_email_address(),
            password                  => $hash_pwd,
            email_verified            => 1,
            residence                 => 'za',
            account_opening_reason    => 'Hedging',
            tax_residence             => 'it',
            tax_identification_number => 'MRTSVT79M29F8_9P',
        },
        [{
                name        => 'VRTC',
                broker_code => 'VRTC',
            },
        ]);

    $params->{country}                 = 'za';
    $params->{args}->{residence}       = 'za';
    $params->{args}->{address_line_1}  = 'sus';
    $params->{args}->{address_city}    = 'sus';
    $params->{args}->{address_state}   = 'gauteng';
    $params->{args}->{client_password} = $hash_pwd;
    $params->{args}->{subtype}         = 'real';
    $params->{args}->{first_name}      = 'Not him';
    $params->{args}->{last_name}       = 'yes';
    $params->{args}->{date_of_birth}   = '1997-01-02';
    $params->{args}->{email}           = $customer->get_email();
    $params->{args}->{phone}           = '+393678916703';
    $params->{args}->{salutation}      = 'hey';
    $params->{args}->{citizen}         = 'za';
    $params->{args}->{accept_risk}     = 1;
    $params->{token}                   = $customer->get_client_token('VRTC');

    $params->{args} = {
        $params->{args}->%*,
        BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1)->%*,
        'tax_residence'             => 'it',
        'tax_identification_number' => 'MRTSVT79M29F8_9P',
    };

    my $result =
        $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('za mf account created successfully')->result;
    ok $result->{client_id}, 'got a client id';

    my $settings = $rpc_ct->call_ok('get_settings', $params)->has_no_system_error->has_no_error('get za account status')->result;

    cmp_bag $settings->{immutable_fields}, [qw/residence/], 'Expected immutable fields';

    my $new_client = BOM::User::Client->new({loginid => $result->{client_id}});
    $new_client->status->set('duplicate_account', 'system', 'Duplicate account - currency change');
    $new_client->status->_clear_all;

    $settings = $rpc_ct->call_ok('get_settings', $params)->has_no_system_error->has_no_error('get za account status')->result;

    cmp_bag $settings->{immutable_fields},
        [
        BOM::User::Client::FA_FIELDS_IMMUTABLE_DUPLICATED->@*,
        qw/residence account_opening_reason citizen date_of_birth first_name last_name salutation tax_identification_number tax_residence address_city address_line_1 address_line_2 address_postcode address_state phone/
        ],
        'Expected immutable fields';

    my $fa = $rpc_ct->call_ok('get_financial_assessment', $params)->has_no_system_error->has_no_error('get za fa')->result;

    my $fa_values = [map { $_ } grep { $fa->{$_} } $settings->{immutable_fields}->@*];
    cmp_bag $fa_values, [BOM::User::Client::FA_FIELDS_IMMUTABLE_DUPLICATED->@*], 'Expected FA values across the immutable fields';

    subtest 'you cannot change these' => sub {
        my $orig_params = +{$params->%*};

        # cannot update fa fields
        for my $fa_field ($fa_values->@*) {
            $params->{args} = +{$orig_params->{args}->%*};
            $params->{args}->{$fa_field} = 'test';
            $rpc_ct->call_ok('new_account_maltainvest', $params)
                ->has_no_system_error->has_error->error_code_is('CannotChangeAccountDetails', 'correct error code.')
                ->error_message_is("You may not change these account details.", 'It should return expected error message')
                ->error_details_is({changed => [$fa_field]});
        }

        cmp_bag $fa_values, [], 'Empty FA immutable fields on this scenario' unless scalar $fa_values->@*;

        $params = +{$orig_params->%*};
    };

    $result = $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('za mf account created successfully')->result;

    ok $result->{client_id}, 'got a second id';

    my $new_client2 = BOM::User::Client->new({loginid => $result->{client_id}});

    subtest 'added from the CR account' => sub {
        $result = $rpc_ct->call_ok('new_account_real', $params)->has_no_system_error->has_no_error('za cr account created successfully')->result;

        $customer->add_client('CR', $result->{client_id});
        $params->{token} = $customer->get_client_token('CR');

        $new_client2->status->set('duplicate_account', 'system', 'Duplicate account - currency change');
        $new_client2->status->_clear_all;

        subtest 'you cannot change these' => sub {
            my $orig_params = +{$params->%*};

            # cannot update fa fields
            for my $fa_field ($fa_values->@*) {
                $params->{args} = +{$orig_params->{args}->%*};
                $params->{args}->{$fa_field} = 'test';
                $rpc_ct->call_ok('new_account_maltainvest', $params)
                    ->has_no_system_error->has_error->error_code_is('CannotChangeAccountDetails', 'correct error code.')
                    ->error_message_is("You may not change these account details.", 'It should return expected error message')
                    ->error_details_is({changed => [$fa_field]});
            }

            cmp_bag $fa_values, [], 'Empty FA immutable fields on this scenario' unless scalar $fa_values->@*;

            $params = +{$orig_params->%*};
        };

        my $time_duration = Date::Utility->new->plus_time_interval('1d')->epoch;
        my $date_duration = Date::Utility->new->plus_time_interval('1d')->date;
        $new_client2->set_exclusion->timeout_until($time_duration);
        $new_client2->save;
        $mock_context->redefine('client_siblings' => sub { return [$new_client2] });
        $result =
            $rpc_ct->call_ok('new_account_maltainvest', $params)
            ->has_no_system_error->has_error->error_code_is('SelfExclusion', 'If password is weak it should return error')
            ->error_message_is(
            "You have chosen to exclude yourself from trading on our website until $date_duration. If you are unable to place a trade or deposit after your self-exclusion period, please contact us via live chat."
            );
        $new_client2->set_exclusion->timeout_until(Date::Utility->new->plus_time_interval('-1d')->epoch);
        $new_client2->save;
        $result =
            $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('za mf account created successfully')->result;
        ok $result->{client_id}, 'got a client id';
        $mock_context->unmock_all;
    };
};

subtest 'MF under Duplicated account - Spain' => sub {
    my $hash_pwd = BOM::User::Password::hashpw('Abcd1234!!');
    my $customer = BOM::Test::Customer->create({
            email                     => 'test+mf+dup+es' . rand(999) . '@binary.com',
            password                  => $hash_pwd,
            email_verified            => 1,
            residence                 => 'es',
            account_opening_reason    => 'Hedging',
            tax_residence             => 'es',
            tax_identification_number => 'MRTSVT79M29F8_9P',
        },
        [{
                name        => 'VRTC',
                broker_code => 'VRTC',
            },
        ]);

    $params->{country}                           = 'es';
    $params->{args}->{residence}                 = 'es';
    $params->{args}->{address_line_1}            = 'sus';
    $params->{args}->{address_city}              = 'sus';
    $params->{args}->{address_state}             = 'albacete';
    $params->{args}->{client_password}           = $hash_pwd;
    $params->{args}->{subtype}                   = 'real';
    $params->{args}->{first_name}                = 'Not ES';
    $params->{args}->{last_name}                 = 'spain is all I feel';
    $params->{args}->{date_of_birth}             = '1997-01-02';
    $params->{args}->{email}                     = $customer->get_email();
    $params->{args}->{phone}                     = '+393678916703';
    $params->{args}->{salutation}                = 'hey';
    $params->{args}->{citizen}                   = 'es';
    $params->{args}->{accept_risk}               = 1;
    $params->{token}                             = $customer->get_client_token('VRTC');
    $params->{args}->{resident_self_declaration} = 1;

    $params->{args} = {
        $params->{args}->%*,
        BOM::Test::Helper::FinancialAssessment::mock_maltainvest_fa(1)->%*,
        'tax_residence'             => 'es',
        'tax_identification_number' => 'MRTSVT79M29F8_9P',
    };

    my $result =
        $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('es mf account created successfully')->result;
    ok $result->{client_id}, 'got a client id';

    my $settings = $rpc_ct->call_ok('get_settings', $params)->has_no_system_error->has_no_error('get es account status')->result;

    cmp_bag $settings->{immutable_fields}, [qw/residence/], 'Expected immutable fields';

    my $new_client = BOM::User::Client->new({loginid => $result->{client_id}});
    $new_client->status->set('duplicate_account', 'system', 'Duplicate account - currency change');

    $settings = $rpc_ct->call_ok('get_settings', $params)->has_no_system_error->has_no_error('get es account status')->result;

    cmp_bag $settings->{immutable_fields},
        [
        BOM::User::Client::FA_FIELDS_IMMUTABLE_DUPLICATED->@*,
        qw/residence account_opening_reason citizen date_of_birth first_name last_name salutation tax_identification_number tax_residence address_city address_line_1 address_line_2 address_postcode address_state phone/
        ],
        'Expected immutable fields';

    my $fa = $rpc_ct->call_ok('get_financial_assessment', $params)->has_no_system_error->has_no_error('get es fa')->result;

    my $fa_values = [map { $_ } grep { $fa->{$_} } $settings->{immutable_fields}->@*];
    cmp_bag $fa_values, [BOM::User::Client::FA_FIELDS_IMMUTABLE_DUPLICATED->@*], 'Expected FA values across the immutable fields';

    $result = $rpc_ct->call_ok('new_account_maltainvest', $params)->has_no_system_error->has_no_error('es mf account created successfully')->result;
    ok $result->{client_id}, 'got a second id';
};

done_testing();
