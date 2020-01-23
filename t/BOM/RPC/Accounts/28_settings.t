use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use Test::BOM::RPC::Client;
use BOM::Test::Helper::FinancialAssessment;
use BOM::Test::Helper::Token;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Email::Address::UseXS;
use Digest::SHA qw(hmac_sha256_hex);
use BOM::Test::Email qw(:no_event);
use LandingCompany::Registry;
use Scalar::Util qw/looks_like_number/;
use BOM::Platform::Token::API;

BOM::Test::Helper::Token::cleanup_redis_tokens();

# init db
my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client->email($email);
$test_client->save;

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;

my $user         = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

my $test_client_cr_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});

$test_client_cr_vr->email('sample@binary.com');
$test_client_cr_vr->save;

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    citizen     => 'at',
});
$test_client_cr->email('sample@binary.com');
$test_client_cr->set_default_account('USD');
$test_client_cr->save;

my $test_client_cr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_cr_2->email('sample@binary.com');
$test_client_cr_2->save;

my $user_cr = BOM::User->create(
    email    => 'sample@binary.com',
    password => $hash_pwd
);

$user_cr->add_client($test_client_cr_vr);
$user_cr->add_client($test_client_cr);
$user_cr->add_client($test_client_cr_2);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $test_client_mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
    citizen     => ''
});
$test_client_mx->email($email);

my $test_client_vr_2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr_2->email($email);
$test_client_vr_2->set_default_account('USD');
$test_client_vr_2->save;

my $email_mlt_mf    = 'mltmf@binary.com';
my $test_client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    residence   => 'at',
});
$test_client_mlt->email($email_mlt_mf);
$test_client_mlt->set_default_account('EUR');
$test_client_mlt->save;

my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    residence   => 'at',
});
$test_client_mf->email($email_mlt_mf);
$test_client_mf->save;

my $user_mlt_mf = BOM::User->create(
    email    => $email_mlt_mf,
    password => $hash_pwd
);
$user_mlt_mf->add_client($test_client_vr_2);
$user_mlt_mf->add_client($test_client_mlt);
$user_mlt_mf->add_client($test_client_mf);

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_client->loginid, 'test token');
my $token_cr       = $m->create_token($test_client_cr->loginid, 'test token');
my $token_cr_2     = $m->create_token($test_client_cr_2->loginid, 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_vr       = $m->create_token($test_client_vr->loginid, 'test token');
my $token_mx       = $m->create_token($test_client_mx->loginid, 'test token');
my $token_mlt      = $m->create_token($test_client_mlt->loginid, 'test token');
my $token_mf       = $m->create_token($test_client_mf->loginid, 'test token');

my $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
my $c = Test::BOM::RPC::Client->new(ua => $t->app->ua);

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
                token => $token,
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

    my $params = {
        token => $token_cr,
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
            'email'                          => 'sample@binary.com',
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
            'user_hash'                      => hmac_sha256_hex($user_cr->email, BOM::Config::third_party()->{elevio}->{account_secret}),
            'has_secret_answer'              => 1,
        });

    $params->{token} = $token;
    $test_client->status->set('tnc_approval', 'system', 1);
    is($c->tcall($method, $params)->{client_tnc_status}, 1, 'tnc status set');
    $params->{token} = $token_vr;
    is_deeply(
        $c->tcall($method, $params),
        {
            'email'             => 'abc@binary.com',
            'country'           => 'Indonesia',
            'residence'         => 'Indonesia',
            'country_code'      => 'id',
            'email_consent'     => '0',
            'has_secret_answer' => '1',
            'user_hash'         => hmac_sha256_hex($user->email, BOM::Config::third_party()->{elevio}->{account_secret}),
        },
        'vr client return less messages'
    );
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
    my $mocked_client = Test::MockModule->new(ref($test_client));
    my $params        = {
        language   => 'EN',
        token      => $token_vr,
        client_ip  => '127.0.0.1',
        user_agent => 'agent',
        args       => {address1 => 'Address 1'}};
    # in normal case the vr client's residence should not be null, so I update is as '' to simulate null
    $test_client_vr->residence('');
    $test_client_vr->save();
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
    $test_client_vr->load;
    isnt($test_client->address_1, 'Address 1', 'But vr account only update residence');

    # test real account
    $params->{token} = $token;
    # Need to delete this parameter so this next call returns the error of interest
    delete $params->{args}{residence};
    my %full_args = (
        address_line_1  => 'address line 1',
        address_line_2  => 'address line 2',
        address_city    => 'address city',
        address_state   => 'BA',
        secret_question => 'testq',
        secret_answer   => 'testa',
        place_of_birth  => undef,
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
        like($res->{error}{message_to_client}, qr/"\Q\U$restricted_country"/, 'error message mentioned the country')
            or note explain $res->{error};
    }
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
    my $old_latest_environment = $test_client->latest_environment;
    mailbox_clear();
    $params->{args}->{email_consent} = 1;

    $test_client->set_authentication('ID_DOCUMENT')->status('pass');
    $test_client->save;

    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    my $res = $c->tcall('get_settings', {token => $token});
    is($res->{tax_identification_number}, $params->{args}{tax_identification_number}, "Check tax information");
    is($res->{tax_residence},             $params->{args}{tax_residence},             "Check tax information");

    ok($add_note_called, 'add_note is called for authenticated call, so the email should be sent to support address');

    $test_client->get_authentication('ID_DOCUMENT')->delete;
    $test_client->status->clear_professional;
    $test_client->save;

    subtest 'Check for citizenship value' => sub {

        subtest 'empty/unspecified' => sub {
            $params->{token} = $token_mx;
            $params->{args} = {%full_args, citizen => ''};
            is($c->tcall($method, $params)->{error}{message_to_client}, 'Citizenship is required.', 'empty value for citizenship');
        };

        $params->{token} = $token;

        subtest 'invalid' => sub {
            $params->{args} = {%full_args, citizen => 'xx'};
            $test_client->citizen('');
            $test_client->save();
            is(
                $c->tcall($method, $params)->{error}{message_to_client},
                'Sorry, our service is not available for your country of citizenship.',
                'invalid value for citizenship'
            );
        };

        subtest 'different value' => sub {
            $params->{args} = {%full_args, citizen => 'bt'};
            $test_client->citizen('at');
            $test_client->save();
            is($c->tcall($method, $params)->{error}{message_to_client}, 'Your citizen cannot be changed.', 'different value for citizenship');
        };
        subtest 'restricted countries' => sub {
            for my $restricted_country (qw(us ir hk my)) {
                $params->{args} = {%full_args, citizen => $restricted_country};
                $test_client->citizen('');
                $test_client->save();
                is($c->tcall($method, $params)->{status}, 1, 'update successfully');
                is($c->tcall('get_settings', {token => $token})->{citizen}, $restricted_country, "Restricted country value for citizenship");

            }
        };

    };
    $test_client->load();

    isnt($test_client->latest_environment, $old_latest_environment, "latest environment updated");

    my $subject = 'Change in account settings';
    my $msg     = mailbox_search(
        email   => $test_client->email,
        subject => qr/\Q$subject\E/
    );
    ok($msg, 'send a email to client');
    like($msg->{body}, qr/address line 1, address line 2, address city, Bali/s, 'email content correct');
    mailbox_clear();

    $params->{args}->{request_professional_status} = 1;

    $params->{token} = $token_cr;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Professional status is not applicable to your account.',
        'professional status is not applicable for all countries'
    );

    $params->{token} = $token;
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    $subject = $test_client->loginid . ' requested for professional status';
    $msg     = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/\Q$subject\E/
    );
    ok($msg, 'send a email to client');
    is_deeply($msg->{to}, ['compliance@binary.com', 'support@binary.com'], 'email to address is ok');
    mailbox_clear();

    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'You already requested professional status.',
        'professional status is already requested'
    );

    $res = $c->tcall('get_settings', {token => $token});
    is($res->{request_professional_status}, 1, "Was able to request professional status");

    # test that postcode is optional for non-MX clients and required for MX clients
    $full_args{address_postcode} = '';

    $params->{args} = {%full_args};
    is($c->tcall($method, $params)->{status}, 1, 'postcode is optional for non-MX clients and can be set to null');

    $params->{token} = $token_mx;
    $params->{args}{account_opening_reason} = 'Income Earning';

    # setting account settings for one client also updates for clients that have a different landing company
    $params->{token} = $token_mlt;
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    is($c->tcall('get_settings', {token => $token_mlt})->{address_line_1}, "address line 1", "Was able to set settings for MLT client");
    is($c->tcall('get_settings', {token => $token_mf})->{address_line_1},  "address line 1", "Was able to set settings for MF client");

    # setting account settings for one client updates for all clients with the same landing company
    $params->{token} = $token_cr_2;
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    is($c->tcall('get_settings', {token => $token_cr})->{address_line_1}, "address line 1", "Was able to set settings correctly for CR client");
    is(
        $c->tcall('get_settings', {token => $token_cr_2})->{address_line_1},
        "address line 1",
        "Was able to set settings correctly for second CR client"
    );
};

done_testing();
