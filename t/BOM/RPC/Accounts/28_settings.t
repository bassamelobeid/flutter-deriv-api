use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::MockTime qw(set_fixed_time restore_time);
use Test::BOM::RPC::QueueClient;
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Helper::Token;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Email::Address::UseXS;
use Digest::SHA qw(hmac_sha256_hex);
use BOM::Test::Email qw(:no_event);
use LandingCompany::Registry;
use Scalar::Util qw/looks_like_number/;
use BOM::Platform::Token::API;
use Guard;

BOM::Test::Helper::Token::cleanup_redis_tokens();

my $app_config  = BOM::Config::Runtime->instance->app_config;
my $orig_config = $app_config->cgi->terms_conditions_versions;
scope_guard { $app_config->cgi->terms_conditions_versions($orig_config) };
my $tnc_version = 'Version 1 2020-01-01';
$app_config->cgi->terms_conditions_versions('{ "deriv": "' . $tnc_version . '" }');

# init db
my $token_gen = BOM::Platform::Token::API->new;
my $hash_pwd  = BOM::User::Password::hashpw('jskjd8292922');

my $email_X = 'abc@binary.com';
my $email_Y = 'sample@binary.com';
my $email_T = 'mlt_mf@binary.com';
my $email_Q = 'abcd@binary.com';

# User X
my $user_X = BOM::User->create(
    email    => $email_X,
    password => $hash_pwd
);

my $test_client_X_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_X_mf->email($email_X);
$test_client_X_mf->save;

my $test_client_X_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code              => 'VRTC',
    non_pep_declaration_time => undef
});
$test_client_X_vr->email($email_X);
$test_client_X_vr->save;

$user_X->add_client($test_client_X_mf);
$user_X->add_client($test_client_X_vr);

# User Y
my $user_Y = BOM::User->create(
    email    => $email_Y,
    password => $hash_pwd
);

my $test_client_Y_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});

$test_client_Y_vr->email($email_Y);
$test_client_Y_vr->save;

my $test_client_Y_cr_citizen_AT = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    citizen     => 'at',
});
$test_client_Y_cr_citizen_AT->email($email_Y);
$test_client_Y_cr_citizen_AT->set_default_account('USD');
$test_client_Y_cr_citizen_AT->save;

my $test_client_Y_cr_1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_Y_cr_1->email($email_Y);
$test_client_Y_cr_1->save;

my $test_client_Y_cr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_Y_cr_2->email($email_Y);
$test_client_Y_cr_2->save;

my $payment_agent_args = {
    payment_agent_name    => $test_client_Y_cr_2->first_name,
    currency_code         => 'USD',
    url                   => 'http://www.example.com/',
    email                 => $test_client_Y_cr_2->email,
    phone                 => $test_client_Y_cr_2->phone,
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
};

#make him payment agent
$test_client_Y_cr_2->payment_agent($payment_agent_args);
$test_client_Y_cr_2->save;
#set countries for payment agent
$test_client_Y_cr_2->get_payment_agent->set_countries(['id', 'in']);

$user_Y->add_client($test_client_Y_vr);
$user_Y->add_client($test_client_Y_cr_citizen_AT);
$user_Y->add_client($test_client_Y_cr_1);
$user_Y->add_client($test_client_Y_cr_2);

# User T
my $user_T = BOM::User->create(
    email    => $email_T,
    password => $hash_pwd
);

my $test_client_T_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
    citizen     => ''
});
$test_client_T_mx->email($email_T);

my $test_client_T_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});

$test_client_T_vr->email($email_T);
$test_client_T_vr->set_default_account('USD');
$test_client_T_vr->save;

my $test_client_T_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    residence   => 'at',
});
$test_client_T_mlt->email($email_T);
$test_client_T_mlt->set_default_account('EUR');
$test_client_T_mlt->save;

my $test_client_T_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    residence   => 'at',
});
$test_client_T_mf->email($email_T);
$test_client_T_mf->save;

$user_T->add_client($test_client_T_vr);
$user_T->add_client($test_client_T_mlt);
$user_T->add_client($test_client_T_mf);

# User Q
my $user_Q = BOM::User->create(
    email    => $email_Q,
    password => $hash_pwd
);

my $test_client_Q_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    residence   => 'id'
});
$user_Q->add_client($test_client_Q_vr);
$test_client_Q_vr->email($email_Q);
$test_client_Q_vr->set_default_account('USD');
$test_client_Q_vr->save;

# Client disabled
my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$test_client_disabled->status->set('disabled', 1, 'test disabled');
my $token_disabled = $token_gen->create_token($test_client_disabled->loginid, 'test token');

my $token_X_mf = $token_gen->create_token($test_client_X_mf->loginid, 'test token');
my $token_X_vr = $token_gen->create_token($test_client_X_vr->loginid, 'test token');

my $token_Y_cr_citizen_AT = $token_gen->create_token($test_client_Y_cr_citizen_AT->loginid, 'test token');
my $token_Y_cr_1          = $token_gen->create_token($test_client_Y_cr_1->loginid,          'test token');
my $token_Y_cr_2          = $token_gen->create_token($test_client_Y_cr_2->loginid,          'test token');

my $token_T_mx  = $token_gen->create_token($test_client_T_mx->loginid,  'test token');
my $token_T_mlt = $token_gen->create_token($test_client_T_mlt->loginid, 'test token');
my $token_T_mf  = $token_gen->create_token($test_client_T_mf->loginid,  'test token');

my $token_Q_vr = $token_gen->create_token($test_client_Q_vr->loginid, 'test token');

my $c = Test::BOM::RPC::QueueClient->new();

my $method = 'get_settings';
subtest 'get settings' => sub {
    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');

    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
        )->{error}{message_to_client},
        'The token is invalid.',
        'invalid token error'
    );
    isnt(
        $c->tcall(
            $method,
            {
                token => $token_X_mf,
            }
        )->{error}{message_to_client},
        'The token is invalid.',
        'no token error if token is valid'
    );

    is(
        $c->tcall(
            $method,
            {
                token => $token_disabled,
            }
        )->{error}{message_to_client},
        'This account is unavailable.',
        'check authorization'
    );

    $user_Y->update_preferred_language('FA');
    my $params = {
        token => $token_Y_cr_citizen_AT,
    };
    my $result = $c->tcall($method, $params);
    note explain $result;
    is_deeply(
        $result,
        {
            'country'                        => 'Indonesia',
            'residence'                      => 'Indonesia',
            'salutation'                     => 'MR',
            'is_authenticated_payment_agent' => '0',
            'country_code'                   => 'id',
            'date_of_birth'                  => '267408000',
            'address_state'                  => 'LA',
            'address_postcode'               => '232323',
            'phone'                          => '+15417543010',
            'last_name'                      => 'pItT',
            'email'                          => $email_Y,
            'address_line_2'                 => '301',
            'address_city'                   => 'Beverly Hills',
            'address_line_1'                 => 'Civic Center',
            'first_name'                     => 'bRaD',
            'email_consent'                  => '0',
            'allow_copiers'                  => '0',
            'client_tnc_status'              => '',
            'place_of_birth'                 => undef,
            'tax_residence'                  => undef,
            'tax_identification_number'      => undef,
            'account_opening_reason'         => undef,
            'request_professional_status'    => 0,
            'citizen'                        => 'at',
            'user_hash'                      => hmac_sha256_hex($user_Y->email, BOM::Config::third_party()->{elevio}->{account_secret}),
            'has_secret_answer'              => 1,
            'non_pep_declaration'            => 1,
            'immutable_fields'               => ['residence', 'secret_answer', 'secret_question'],
            'preferred_language'             => 'FA',
        });

    $user_X->update_preferred_language('AZ');
    $params->{token} = $token_X_mf;
    $test_client_X_mf->user->set_tnc_approval;
    $result = $c->tcall($method, $params);

    is($result->{client_tnc_status},  $tnc_version, 'tnc status set');
    is($result->{preferred_language}, 'AZ',         'preferred_language set');

    $user_Q->update_preferred_language('EN');
    $params->{token} = $token_Q_vr;
    is_deeply(
        $c->tcall($method, $params),
        {
            'email'              => $email_Q,
            'country'            => 'Indonesia',
            'residence'          => 'Indonesia',
            'country_code'       => 'id',
            'email_consent'      => '0',
            'user_hash'          => hmac_sha256_hex($user_Q->email, BOM::Config::third_party()->{elevio}->{account_secret}),
            'immutable_fields'   => ['residence'],
            'preferred_language' => 'EN'
        },
        'vr client return less messages when it does not have real sibling'
    );

    $params->{token} = $token_X_vr;
    $result = $c->tcall($method, $params);
    is_deeply(
        $result,
        {
            'country'                        => 'Indonesia',
            'residence'                      => 'Indonesia',
            'salutation'                     => 'MR',
            'is_authenticated_payment_agent' => '0',
            'country_code'                   => 'id',
            'date_of_birth'                  => '267408000',
            'address_state'                  => 'LA',
            'address_postcode'               => '232323',
            'phone'                          => '+15417543010',
            'last_name'                      => 'pItT',
            'email'                          => $email_X,
            'address_line_2'                 => '301',
            'address_city'                   => 'Beverly Hills',
            'address_line_1'                 => 'Civic Center',
            'first_name'                     => 'bRaD',
            'email_consent'                  => '0',
            'allow_copiers'                  => '0',
            'client_tnc_status'              => '',
            'place_of_birth'                 => undef,
            'tax_residence'                  => undef,
            'tax_identification_number'      => undef,
            'account_opening_reason'         => undef,
            'request_professional_status'    => 0,
            'citizen'                        => 'at',
            'user_hash'                      => hmac_sha256_hex($user_X->email, BOM::Config::third_party()->{elevio}->{account_secret}),
            'has_secret_answer'              => 1,
            'non_pep_declaration'            => 0,
            'immutable_fields'               => ['residence'],
            'preferred_language'             => 'AZ'
        },
        'vr client return real account information when it has sibling'
    );
    $user_X->update_preferred_language('DE');
    $result = $c->tcall($method, $params);
    is $result->{preferred_language}, 'DE', 'preferred language reset';

    $params->{token} = $token_Y_cr_2;
    $result = $c->tcall($method, $params);
    my $expected = {
        'country'                        => 'Indonesia',
        'residence'                      => 'Indonesia',
        'salutation'                     => 'MR',
        'is_authenticated_payment_agent' => '1',
        'country_code'                   => 'id',
        'date_of_birth'                  => '267408000',
        'address_state'                  => 'LA',
        'address_postcode'               => '232323',
        'phone'                          => '+15417543010',
        'last_name'                      => 'pItT',
        'email'                          => $email_Y,
        'address_line_2'                 => '301',
        'address_city'                   => 'Beverly Hills',
        'address_line_1'                 => 'Civic Center',
        'first_name'                     => 'bRaD',
        'email_consent'                  => '0',
        'allow_copiers'                  => '0',
        'client_tnc_status'              => '',
        'place_of_birth'                 => undef,
        'tax_residence'                  => undef,
        'tax_identification_number'      => undef,
        'account_opening_reason'         => undef,
        'request_professional_status'    => 0,
        'citizen'                        => 'at',
        'user_hash'                      => hmac_sha256_hex($user_Y->email, BOM::Config::third_party()->{elevio}->{account_secret}),
        'has_secret_answer'              => 1,
        'non_pep_declaration'            => 1,
        'immutable_fields'               => ['residence', 'secret_answer', 'secret_question'],
        'preferred_language'             => 'FA',
    };
    is_deeply($result, $expected, 'return 1 for authenticated payment agent');

    $test_client_Y_cr_2->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $test_client_Y_cr_2->save;
    ok $test_client_Y_cr_2->fully_authenticated, 'client is authenticated';
    $result = $c->tcall($method, $params);
    $expected->{immutable_fields} =
        ['citizen', 'date_of_birth', 'first_name', 'last_name', 'residence', 'salutation', 'secret_answer', 'secret_question'];
    is_deeply($result, $expected, 'immutable fields changed after authentication');
    $test_client_Y_cr_2->set_authentication('ID_DOCUMENT', {status => 'fail'});
    $test_client_Y_cr_2->save;

    ok !$test_client_Y_cr_2->fully_authenticated, 'authentication is removed';
    $result = $c->tcall($method, $params);
    $expected->{immutable_fields} = ['residence', 'secret_answer', 'secret_question'];
    is_deeply($result, $expected, 'immutable fields changed back to pre-authentication list');
};

$method = 'set_settings';
subtest 'set settings' => sub {
    my $emitted;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->mock(
        'emit',
        sub {
            my ($type, $data) = @_;
            if ($type eq 'send_email') {
                return BOM::Platform::Email::process_send_email($data);
            } else {
                $emitted->{$type} = $data;
            }
        });

    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');

    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
        )->{error}{message_to_client},
        'The token is invalid.',
        'invalid token error'
    );

    is(
        $c->tcall(
            $method,
            {
                token => $token_disabled,
            }
        )->{error}{message_to_client},
        'This account is unavailable.',
        'check authorization'
    );
    my $mocked_client = Test::MockModule->new(ref($test_client_X_mf));
    my $params        = {
        language   => 'EN',
        token      => $token_X_vr,
        client_ip  => '127.0.0.1',
        user_agent => 'agent',
        args       => {address1 => 'Address 1'}};
    # in normal case the vr client's residence should not be null, so I update is as '' to simulate null
    $test_client_X_vr->residence('');
    $test_client_X_vr->save();
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', "vr client can only update residence");
    # here I mocked function 'save' to simulate the db failure.
    $mocked_client->mock('save', sub { return undef });
    $params->{args}{residence} = 'zh';
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, our service is not available for your country of residence.',
        'return error if cannot save'
    );
    $mocked_client->unmock('save');
    # testing invalid residence, expecting save to fail
    my $result = $c->tcall($method, $params);
    is($result->{status}, undef, 'invalid residence should not be able to save');
    # testing valid residence, expecting save to pass
    $params->{args}{residence} = 'kr';
    $result = $c->tcall($method, $params);
    is($result->{status}, 1, 'vr account update residence successfully');
    $test_client_X_vr->load;
    isnt($test_client_X_mf->address_1, 'Address 1', 'But vr account only update residence');

    # test real account
    $params->{token} = $token_X_mf;
    # Need to delete this parameter so this next call returns the error of interest
    delete $params->{args}{residence};
    my %full_args = (
        address_line_1  => 'address line 1',
        address_line_2  => 'address line 2',
        address_city    => 'address city',
        address_state   => 'BA',
        secret_question => 'testq',
        secret_answer   => 'testa',
        place_of_birth  => undef
    );

    $params->{args}{residence} = 'kr';
    $full_args{account_opening_reason} = 'Income Earning';

    $params->{args} = {%{$params->{args}}, %full_args};
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Permission denied.', 'real account cannot update residence');
    $params->{args} = {%full_args};

    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Your secret answer cannot be changed.',
        'Cannot send secret_answer if already exists'
    );
    delete $params->{args}{secret_answer};

    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Your secret question cannot be changed.',
        'Cannot send secret_question if already exists'
    );
    delete $params->{args}{secret_question};

    delete $full_args{secret_question};
    delete $full_args{secret_answer};

    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Tax-related information is mandatory for legal and regulatory requirements. Please provide your latest tax information.',
        'Correct tax error message'
    );

    $full_args{tax_residence}             = 'de';
    $full_args{tax_identification_number} = '111-222-333';

    $params->{args} = {%full_args};
    delete $params->{args}{address_line_1};

    $params->{args}{date_of_birth} = '1987-1-1';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Your date of birth cannot be changed.', 'date_of_birth not allow changed');
    delete $params->{args}{date_of_birth};

    $params->{args}{place_of_birth} = 'xx';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Please enter a valid place of birth.', 'place_of_birth no exists');
    $params->{args}{place_of_birth} = 'de';

    is($c->tcall($method, $params)->{status}, 1, 'can update without sending all required fields');
    ok($emitted->{sync_onfido_details}, 'event exists');

    my $event_data = delete $emitted->{sync_onfido_details};
    is($event_data->{loginid},          'MF90000000', 'Correct loginid');
    is($emitted->{sync_onfido_details}, undef,        'sync_onfido_details event does not exists');

    is($c->tcall($method, $params)->{status}, 1, 'can send set_settings with same value');
    {
        local $full_args{place_of_birth} = 'at';
        $params->{args} = {%full_args};

        is(
            $c->tcall($method, $params)->{error}{message_to_client},
            'Your place of birth cannot be changed.',
            'cannot send place_of_birth with a different value'
        );
    }

    $test_client_X_mf->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $test_client_X_mf->save;
    ok $test_client_X_mf->fully_authenticated, 'client is authenticated';

    for my $tax_field (qw(tax_residence tax_identification_number)) {
        local $params->{args} = {
            $tax_field => '',
        };

        my $res = $c->tcall($method, $params);
        is($res->{error}{code}, 'PermissionDenied', $tax_field . ' cannot be removed once it has been set');
    }
    for my $restricted_country (qw(us ir hk my)) {
        local $params->{args} = {
            tax_residence             => $restricted_country,
            tax_identification_number => '111-222-543',
        };

        my $res = $c->tcall($method, $params);
        is($res->{error}{code}, 'RestrictedCountry', 'restricted country ' . $restricted_country . ' for tax residence is blocked as expected')
            or note explain $res;
    }
    # Testing the comma-separated list form of input separately
    for my $restricted_country (qw(us ir hk)) {
        local $params->{args} = {
            tax_residence             => "id,$restricted_country,my",
            tax_identification_number => '111-222-543',
        };

        my $res = $c->tcall($method, $params);
        is($res->{error}{code},
            'RestrictedCountry', 'one restricted country (' . $restricted_country . ') in list of tax residences is also blocked as expected')
            or note explain $res;
        like($res->{error}{message_to_client}, qr/"\Q$restricted_country"/, 'error message mentioned the country')
            or note explain $res->{error};
    }

    $test_client_X_mf->set_authentication('ID_DOCUMENT', {status => 'fail'});
    $test_client_X_mf->save;
    ok !$test_client_X_mf->fully_authenticated, 'client is not authenticated';

    for my $unrestricted_country (qw(id ru)) {
        local $params->{args} = {
            tax_residence             => $unrestricted_country,
            tax_identification_number => '111-222-543',
        };
        my $res = $c->tcall($method, $params);
        is($res->{status}, 1, 'unrestricted country ' . $unrestricted_country . ' for tax residence is allowed') or note explain $res;
    }
    {
        local $full_args{account_opening_reason} = 'Hedging';
        $params->{args} = {%full_args};
        is(
            $c->tcall($method, $params)->{error}{message_to_client},
            'Your account opening reason cannot be changed.',
            'cannot send account_opening_reason with a different value'
        );
    }

    delete $params->{args}->{account_opening_reason};
    $params->{args}->{phone} = '+11111111';
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Please enter a valid phone number, including the country code (e.g. +15417541234).',
        'Cannot send invalid phone number'
    );
    delete $params->{args}->{phone};

    $params->{args} = {%full_args};
    $mocked_client->mock('save', sub { return undef });
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your request.',
        'return error if cannot save'
    );
    $mocked_client->unmock_all;

    # add_note should send an email to support address,
    # but it is disabled when the test is running on travis-ci
    # so I mocked this function to check it is called.
    my $add_note_called;
    $mocked_client->mock('add_note', sub { $add_note_called = 1; });
    my $old_latest_environment = $test_client_X_mf->latest_environment;
    mailbox_clear();
    $params->{args}->{email_consent} = 1;

    $test_client_X_mf->set_authentication('ID_DOCUMENT', {status => 'pass'});
    $test_client_X_mf->save;

    $params->{args}{tax_identification_number} = '111-222-543';
    $params->{args}{tax_residence}             = 'de';
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Your tax residence cannot be changed.',
        'Can not change tax residence for MF once it has been authenticated.'
    );
    $params->{args}{tax_identification_number} = '111-222-333';
    $params->{args}{tax_residence}             = 'ru';
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Your tax identification number cannot be changed.',
        'Can not change tax identification number for MF once it has been authenticated.'
    );

    $params->{args}{tax_identification_number} = '111-222-543';
    $params->{args}{tax_residence}             = 'ru';
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    my $res = $c->tcall('get_settings', {token => $token_X_mf});
    is($res->{tax_identification_number}, $params->{args}{tax_identification_number}, "Check tax information");
    is($res->{tax_residence},             $params->{args}{tax_residence},             "Check tax information");

    ok($add_note_called, 'add_note is called for authenticated call, so the email should be sent to support address');

    $test_client_X_mf->get_authentication('ID_DOCUMENT')->delete;
    $test_client_X_mf->status->clear_professional;
    $test_client_X_mf->save;

    subtest 'preferred language setting' => sub {
        $params->{token} = $token_X_mf;

        $params->{args} = {%full_args, preferred_language => 'FA'};
        is($c->tcall($method, $params)->{status},                                   1,    'update successfully');
        is($c->tcall('get_settings', {token => $token_X_mf})->{preferred_language}, 'FA', 'preferred language updated.');

        $params->{args} = {%full_args, preferred_language => undef};
        is($c->tcall($method, $params)->{status},                                   1,    'update successfully');
        is($c->tcall('get_settings', {token => $token_X_mf})->{preferred_language}, 'FA', 'preferred language updated.');
    };

    subtest 'Check for citizenship value' => sub {

        subtest 'empty/unspecified' => sub {
            $params->{token} = $token_T_mx;
            $params->{args}  = {%full_args, citizen => ''};
            is($c->tcall($method, $params)->{error}{message_to_client}, 'This field is required.', 'empty value for citizenship');
        };

        $params->{token} = $token_X_mf;

        subtest 'invalid' => sub {
            $params->{args} = {%full_args, citizen => 'xx'};
            $test_client_X_mf->citizen('');
            $test_client_X_mf->save();
            is(
                $c->tcall($method, $params)->{error}{message_to_client},
                'Sorry, our service is not available for your country of citizenship.',
                'invalid value for citizenship'
            );
        };

        subtest 'different value' => sub {
            $params->{args} = {%full_args, citizen => 'bt'};
            $test_client_X_mf->citizen('at');
            $test_client_X_mf->save();
            is($c->tcall($method, $params)->{error}{message_to_client}, 'Your citizenship cannot be changed.', 'different value for citizenship');
        };
        subtest 'restricted countries' => sub {
            for my $restricted_country (qw(us ir hk my)) {
                $params->{args} = {%full_args, citizen => $restricted_country};
                $test_client_X_mf->citizen('');
                $test_client_X_mf->save();
                is($c->tcall($method, $params)->{status},                        1,                   'update successfully');
                is($c->tcall('get_settings', {token => $token_X_mf})->{citizen}, $restricted_country, "Restricted country value for citizenship");

            }
        };
        subtest 'po box' => sub {
            subtest 'regulated account' => sub {
                $test_client_T_mx->citizen('gb');
                $test_client_T_mx->save;

                my $params = {
                    token      => $token_T_mx,
                    language   => 'EN',
                    client_ip  => '127.0.0.1',
                    user_agent => 'agent',
                    args       => {address_line_1 => 'P.O. box 25243'}};

                my $response = $c->tcall($method, $params);
                is $response->{error}->{message_to_client}, 'P.O. Box is not accepted in address.', 'Invalid P.O. Box in address';
            };

            subtest 'unregulated account' => sub {
                $test_client_Y_cr_citizen_AT->citizen('br');
                $test_client_Y_cr_citizen_AT->save;

                my $params = {
                    token      => $token_Y_cr_citizen_AT,
                    language   => 'EN',
                    client_ip  => '127.0.0.1',
                    user_agent => 'agent',
                    args       => {address_line_1 => 'P.O. box 25243'}};

                my $response = $c->tcall($method, $params);
                is $response->{status}, 1, 'P.O. box not checked for unregulated account';
            };
        };
    };
    subtest 'non-pep declaration' => sub {
        is $test_client_X_vr->non_pep_declaration_time, undef, 'non-pep declaration time is undefined for virtual accounts';
        $params->{token} = $token_X_vr;
        $params->{args}  = {non_pep_declaration => 1};
        is($c->tcall($method, $params)->{status}, 1, 'vr account updated successfully');
        $test_client_X_vr->load;
        is $test_client_X_vr->non_pep_declaration_time, undef, 'non-pep declaration is not changed for virtual accounts';

        for my $client ($test_client_Y_cr_citizen_AT, $test_client_Y_cr_1) {
            $client->non_pep_declaration_time('1999-01-01 00:00:00');
            $client->save;
            $client->load;
            is $client->non_pep_declaration_time, '1999-01-01 00:00:00', 'Declaration time is set to a test value';
        }
        $params->{token} = $token_Y_cr_citizen_AT;
        $params->{args}  = {%full_args, non_pep_declaration => 1};
        is($c->tcall($method, $params)->{status}, 1, 'update successfully');

        for my $client ($test_client_Y_cr_citizen_AT, $test_client_Y_cr_1) {
            $client->load;
            is $client->non_pep_declaration_time, '1999-01-01 00:00:00', 'Decaration time is not changed if it isnt empty';
        }

        # simulate a client with empty non-pep declaration time (because it's impossible to set it to null for real accounts in DB)
        my $mocked_client = Test::MockModule->new(ref($test_client_X_mf));
        $mocked_client->mock(
            non_pep_declaration_time => sub {
                my ($self) = @_;
                # return undef only the first time it's read and let it act normally afterwards.
                if (scalar @_ == 1 && !$self->{__non_pep_called}) {
                    $self->{__non_pep_called} = 1;
                    return undef;
                }
                return $mocked_client->original('non_pep_declaration_time')->(@_);
            });
        my $fixed_time = Date::Utility->new('2018-02-15');
        set_fixed_time($fixed_time->epoch);
        is($c->tcall($method, $params)->{status}, 1, 'update successfully');
        $mocked_client->unmock_all;
        restore_time();

        for my $client ($test_client_Y_cr_citizen_AT, $test_client_Y_cr_1) {
            $client->load;
            is $client->non_pep_declaration_time, '2018-02-15 00:00:00', 'Decaration time is changed for siblings if it is null';
        }
    };

    $params->{token} = $token_X_mf;
    $test_client_X_mf->load();

    isnt($test_client_X_mf->latest_environment, $old_latest_environment, "latest environment updated");

    my $subject = 'Change in account settings';
    my $msg     = mailbox_search(
        email   => $test_client_X_mf->email,
        subject => qr/\Q$subject\E/
    );
    ok($msg, 'send a email to client');
    like($msg->{body}, qr/address line 1, address line 2, address city, Bali/s, 'email content correct');
    mailbox_clear();

    $params->{args}->{request_professional_status} = 1;

    $params->{token} = $token_Y_cr_citizen_AT;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Professional status is not applicable to your account.',
        'professional status is not applicable for all countries'
    );

    $params->{token} = $token_X_mf;
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    $subject = $test_client_X_mf->loginid . ' requested for professional status';
    $msg     = mailbox_search(
        email   => 'compliance@deriv.com',
        subject => qr/\Q$subject\E/
    );
    ok($msg, 'send a email to client');
    is_deeply($msg->{to}, ['compliance@deriv.com'], 'email to address is ok');
    mailbox_clear();

    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'You already requested professional status.',
        'professional status is already requested'
    );

    $res = $c->tcall('get_settings', {token => $token_X_mf});
    is($res->{request_professional_status}, 1, "Was able to request professional status");

    # test that postcode is optional for non-MX clients and required for MX clients
    $full_args{address_postcode} = '';

    $params->{args} = {%full_args};
    is($c->tcall($method, $params)->{status}, 1, 'postcode is optional for non-MX clients and can be set to null');

    $params->{token} = $token_T_mx;
    $params->{args}{account_opening_reason} = 'Income Earning';

    delete $emitted->{profile_change};
    # setting account settings for one client also updates for clients that have a different landing company
    $params->{token} = $token_T_mlt;
    $params->{args}->{place_of_birth} = 'ir';
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    ok($emitted->{profile_change}, 'profile_change emit exist');

    is_deeply $emitted->{profile_change}->{properties}->{updated_fields}, $params->{args}, "updated fields are correctly sent to track event";
    is($c->tcall('get_settings', {token => $token_T_mlt})->{address_line_1}, "address line 1", "Was able to set settings for MLT client");
    is($c->tcall('get_settings', {token => $token_T_mf})->{address_line_1},  "address line 1", "Was able to set settings for MF client");

    # setting account settings for one client updates for all clients with the same landing company
    $params->{token} = $token_Y_cr_1;
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    ok($emitted->{profile_change}, 'profile_change emit exist');
    is_deeply $emitted->{profile_change}->{properties}->{updated_fields},
        {
        'place_of_birth'   => 'ir',
        'address_postcode' => ''
        },
        "updated fields are correctly sent to track event";
    is(
        $c->tcall('get_settings', {token => $token_Y_cr_citizen_AT})->{address_line_1},
        "address line 1",
        "Was able to set settings correctly for CR client"
    );
    is(
        $c->tcall('get_settings', {token => $token_Y_cr_1})->{address_line_1},
        "address line 1",
        "Was able to set settings correctly for second CR client"
    );
};

subtest 'set_settings on virtual account should not change real account settings' => sub {
    my $get_settings_cr = $c->tcall('get_settings', {token => $token_Y_cr_1});

    my $params = {
        language   => 'EN',
        token      => $token_Q_vr,
        client_ip  => '127.0.0.1',
        user_agent => 'agent',
        args       => {email_consent => '0'}};    # VR can change email_consent

    is($c->tcall('set_settings', $params)->{status}, 1, 'VR account email_consent changed successfully');

    my $result = $c->tcall('get_settings', {token => $token_Y_cr_1});
    is($result->{email_consent}, $params->{args}{email_consent}, "CR account email_consent setting changed successfully");

    my $expected_result = {$get_settings_cr->%*, email_consent => $params->{args}{email_consent}};
    is_deeply($result, $expected_result, 'CR account settings remain unchanged');
};

done_testing();
