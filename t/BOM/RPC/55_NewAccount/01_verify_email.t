use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::Fatal qw(lives_ok);
use MojoX::JSON::RPC::Client;
use BOM::User::Password;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Email                           qw(:no_event);
use BOM::RPC::v3::Utility;
use BOM::Platform::Token::API;
use BOM::Database::Model::AccessToken;
use BOM::User;
use BOM::Test::Helper::Token qw(cleanup_redis_tokens);
use BOM::Test::Helper::Client;

use BOM::Test::RPC::QueueClient;
use Data::Dumper;

use utf8;

$ENV{EMAIL_SENDER_TRANSPORT} = 'Test';
my ($user, $client, $email);
my $rpc_ct;
my $method = 'verify_email';

my $should_cellxpert_api_for_is_username_available_fail = 0;
my $is_affiliate_username_available                     = 0;
my $mock_cellxpert_server                               = Test::MockModule->new('WebService::Async::Cellxpert');
$mock_cellxpert_server->mock(
    'is_username_available',
    sub {
        if ($should_cellxpert_api_for_is_username_available_fail) {
            return Future->fail({result => "not ok"});
        } else {
            if ($is_affiliate_username_available) {
                return Future->done(1);
            } else {
                return Future->done(0);
            }

        }
    });

my @params = (
    $method,
    {
        language => 'EN',
        country  => 'ru',
        source   => 1,
    });

{
    # cleanup
    cleanup_redis_tokens();
    BOM::Database::Model::AccessToken->new->dbic->dbh->do('DELETE FROM auth.access_token');
}

my $expected_result = {
    stash => {
        app_markup_percentage      => 0,
        valid_source               => 1,
        source_bypass_verification => 0,
        source_type                => 'official',
    },
    status => 1
};

subtest 'Initialization' => sub {
    lives_ok {
        my $password = 'jskjd8292922';
        my $hash_pwd = BOM::User::Password::hashpw($password);

        $email = 'exists_email' . rand(999) . '@binary.com';

        $user = BOM::User->create(
            email    => $email,
            password => $hash_pwd
        );

        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });

        $client->account('USD');
        $user->add_client($client);
    }
    'Initial user and client';

    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

subtest 'Account opening request with an invalid email address' => sub {
    mailbox_clear();
    $params[1]->{args}->{verify_email}                 = 'test' . rand(999) . '.@binary.com';
    $params[1]->{args}->{type}                         = 'account_opening';
    $params[1]->{args}->{url_parameters}->{utm_medium} = 'email';
    $params[1]->{server_name}                          = 'deriv.com';
    $params[1]->{link}                                 = 'deriv.com/some_url';

    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('InvalidEmail', 'If email address is invalid it should return error')
        ->error_message_is('This email address is invalid.', 'If email address is invalid it should return error_message');
};

#Todo: these 3 old endpoints tests should be remove after removing partner_account_opening in websocket-api schema

subtest 'Partner account opening request if affiliate exists on CellXpert thirdparty' => sub {
    $params[1]->{args}->{verify_email} = 'test' . rand(999) . '@binary.com';
    $params[1]->{args}->{type}         = 'partner_account_opening';

    my $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_system_error->has_error()->result;
    is $result->{error}->{code}, 'CXUsernameExists', 'A user with this email already exists';
};

subtest 'Partner account opening request if affiliate NOT exists on CellXpert thirdparty' => sub {
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { push @emitted, @_ };
    $is_affiliate_username_available   = 1;
    $params[1]->{args}->{verify_email} = 'test' . rand(999) . '@binary.com';
    $params[1]->{args}->{type}         = 'partner_account_opening';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

};

subtest 'Partner account opening request if cellXpert webservice raise error' => sub {
    $should_cellxpert_api_for_is_username_available_fail = 1;
    $params[1]->{args}->{verify_email}                   = 'test' . rand(999) . '@binary.com';
    $params[1]->{args}->{type}                           = 'partner_account_opening';

    my $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_system_error->has_error()->result;
    is $result->{error}->{code}, 'CXRuntimeError', 'Could not register user';
};

$params[0] = 'verify_email_cellxpert';

subtest 'Partner account opening request if affiliate exists on CellXpert thirdparty (new Endpoint)' => sub {
    $should_cellxpert_api_for_is_username_available_fail = 0;
    $is_affiliate_username_available                     = 0;
    $params[1]->{args}->{verify_email_cellxpert}         = 'test' . rand(999) . '@binary.com';
    $params[1]->{args}->{type}                           = 'partner_account_opening';

    my $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_system_error->has_error()->result;
    is $result->{error}->{code}, 'CXUsernameExists', 'A user with this email already exists';
};

subtest 'Partner account opening request if affiliate NOT exists on CellXpert thirdparty  (new Endpoint)' => sub {
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { push @emitted, @_ };
    $is_affiliate_username_available             = 1;
    $params[1]->{args}->{verify_email_cellxpert} = 'test' . rand(999) . '@binary.com';
    $params[1]->{args}->{type}                   = 'partner_account_opening';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

};

subtest 'Partner account opening request if cellXpert webservice raise error  (new Endpoint)' => sub {
    $should_cellxpert_api_for_is_username_available_fail = 1;
    $params[1]->{args}->{verify_email_cellxpert}         = 'test' . rand(999) . '@binary.com';
    $params[1]->{args}->{type}                           = 'partner_account_opening';

    my $result = $rpc_ct->call_ok(@params)->has_no_system_error->has_no_system_error->has_error()->result;
    is $result->{error}->{code}, 'CXRuntimeError', 'Could not register user';
};

$params[0] = 'verify_email';

subtest 'Account opening request with email does not exist' => sub {
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { push @emitted, @_ };
    $params[1]->{args}->{verify_email}                 = 'test' . rand(999) . '@binary.com';
    $params[1]->{args}->{type}                         = 'account_opening';
    $params[1]->{args}->{url_parameters}->{utm_medium} = 'email';
    $params[1]->{server_name}                          = 'binary.com';
    $params[1]->{link}                                 = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");
    is($emitted[0], 'account_opening_new', 'type=account_opening_new');
    is $emitted[1]->{email}, $params[1]->{args}->{verify_email}, 'email is set';
    is $emitted[1]->{verification_url},
        'https://www.binary.com/en/redirect.html?action=signup&lang=EN&code=' . $emitted[1]->{code} . '&utm_medium=email',
        'verification_url is set';
    is $emitted[1]->{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
};

subtest 'Account opening request with email exists' => sub {
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { push @emitted, @_ };

    $params[1]->{args}->{verify_email}                 = uc $email;
    $params[1]->{args}->{type}                         = 'account_opening';
    $params[1]->{args}->{url_parameters}->{utm_medium} = 'email';
    $params[1]->{server_name}                          = 'deriv.com';
    $params[1]->{link}                                 = 'deriv.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is($emitted[0],                      'account_opening_existing',            'type=account_opening_existing');
    is($emitted[1]->{properties}{email}, lc $params[1]->{args}->{verify_email}, 'email is set');
    is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
    is($emitted[1]->{properties}->{password_reset_url}, 'https://www.binary.com/en/user/lost_passwordws.html', 'password_reset_url is set');
};

subtest 'Reset password for exists user' => sub {
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { @emitted = @_ };

    $params[1]->{args}->{verify_email} = $email;
    $params[1]->{args}->{type}         = 'reset_password';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is($emitted[0], 'reset_password_request', 'type=reset_password_request');
    ok $emitted[1]->{properties}->{code}, 'code generated';
    my $code = $emitted[1]->{properties}->{code};
    is($emitted[1]->{properties}{email}, lc $params[1]->{args}->{verify_email}, 'email is set');
    is(
        $emitted[1]->{properties}{verification_url},
        'https://www.binary.com/en/redirect.html?action=reset_password&lang=EN&code=' . $code . '&utm_medium=email',
        'the verification_url is correct'
    );
};

subtest 'Change email for not exists user' => sub {
    $params[1]->{args}->{verify_email} = 'not_' . $email;
    $params[1]->{args}->{type}         = 'request_email';
    $params[1]->{server_name}          = 'deriv.com';
    $params[1]->{link}                 = 'deriv.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");
};

subtest 'Payment agent withdraw' => sub {
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { @emitted = @_ };

    $params[1]->{args}->{verify_email} = $client->email;
    $params[1]->{args}->{type}         = 'paymentagent_withdraw';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    $params[1]->{token} = $token;

    subtest 'given zero balance account should not send withdrawl verify email' => sub {
        $rpc_ct->call_ok(@params)->has_error->error_code_is('NoBalanceVerifyMail');
    };

    BOM::Test::Helper::Client::top_up($client, $client->currency, 10);

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is($emitted[0], 'request_payment_withdraw', 'type=request_payment_withdraw');
    ok($emitted[1]->{properties}, 'Properties are set');
    is($emitted[1]->{properties}{email}, lc $params[1]->{args}->{verify_email}, 'email is set');
    is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
    is(
        $emitted[1]->{properties}->{verification_url},
        'https://www.binary.com/en/redirect.html?action=payment_agent_withdraw&lang=EN&code='
            . $emitted[1]->{properties}->{code}
            . '&loginid='
            . $client->loginid
            . '&utm_medium=email',
        'the verification_url is correct'
    );
    undef @emitted;

    $params[1]->{args}->{verify_email} = 'dummy@email.com';
    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    delete $params[1]->{token};
    is(scalar @emitted, 0, 'no email as token email different from passed email');
};

subtest 'Payment withdraw' => sub {
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { @emitted = @_ };

    $params[1]->{args}->{verify_email} = $client->email;
    $params[1]->{args}->{type}         = 'payment_withdraw';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token 1');
    $params[1]->{token} = $token;

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is($emitted[0], 'request_payment_withdraw', 'type=request_payment_withdraw');
    ok($emitted[1]->{properties}, 'Properties are set');
    is($emitted[1]->{properties}{email}, lc $params[1]->{args}->{verify_email}, 'email is set');
    is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
    is(
        $emitted[1]->{properties}->{verification_url},
        'https://www.binary.com/en/redirect.html?action=payment_withdraw&lang=EN&code='
            . $emitted[1]->{properties}->{code}
            . '&loginid='
            . $client->loginid
            . '&utm_medium=email',
        'the verification_url is correct'
    );
    undef @emitted;

    subtest 'payment agent restrictions' => sub {
        my $mock_pa = Test::MockObject->new;
        $mock_pa->mock(status                       => sub { 'authorized' });
        $mock_pa->mock(tier_details                 => sub { return {} });
        $mock_pa->mock(sibling_payment_agents       => sub { return () });
        $mock_pa->mock(cashier_withdrawable_balance => sub { return {available => 0, commission => 0} });

        my $mock_client = Test::MockModule->new('BOM::User::Client');
        $mock_client->redefine(get_payment_agent => $mock_pa);

        $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token 1');
        $params[1]->{token} = $token;

        $rpc_ct->call_ok(@params)
            ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier withdrawal is not available for PAs by default')
            ->error_message_is('This service is not available for payment agents.', 'Serivce unavailability error message');

        $mock_client->unmock_all;
    };

    $params[1]->{args}->{verify_email} = 'dummy@email.com';
    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is(scalar @emitted, 0, 'no email as token email different from passed email');
    delete $params[1]->{token};
};

subtest 'Closed account' => sub {

    $client->status->set('disabled', 1, 'test disabled');

    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { @emitted = @_ };

    $params[1]->{args}->{verify_email} = $email;
    $params[1]->{args}->{type}         = 'account_opening';
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('no error for disabled account')
        ->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is($emitted[0], 'verify_email_closed_account_account_opening', 'type=verify_email_closed_account_account_opening');
    ok($emitted[1]->{properties}, 'Properties are set');
    is($emitted[1]->{properties}{email}, lc $params[1]->{args}->{verify_email}, 'email is set');
    is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
    undef @emitted;

    my $client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $user->add_client($client2);

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('no error after adding a non-disabled account')
        ->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is($emitted[0], 'account_opening_existing', 'type=account_opening_existing');
    ok($emitted[1]->{properties}, 'Properties are set');
    is($emitted[1]->{properties}{email}, lc $params[1]->{args}->{verify_email}, 'email is set');
    is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
    is($emitted[1]->{properties}->{password_reset_url}, 'https://www.binary.com/en/user/lost_passwordws.html', 'password_reset_url is set');
    undef @emitted;

    $client2->status->set('disabled', 1, 'test disabled');

    $params[1]->{args}->{type} = 'reset_password';

    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('no error for disabled account')
        ->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is($emitted[0], 'verify_email_closed_account_reset_password', 'type=verify_email_closed_account_reset_password');
    ok($emitted[1]->{properties}, 'Properties are set');
    is($emitted[1]->{properties}{email}, lc $params[1]->{args}->{verify_email}, 'email is set');
    is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
    undef @emitted;

    $params[1]->{args}->{type} = 'payment_withdraw';
    $rpc_ct->call_ok(@params)->has_no_system_error->has_no_error('no error for disabled account')
        ->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is($emitted[0], 'verify_email_closed_account_other', 'type=verify_email_closed_account_other');
    ok($emitted[1]->{properties}, 'Properties are set');
    is($emitted[1]->{properties}{email}, lc $params[1]->{args}->{verify_email}, 'email is set');
    is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
};

subtest 'withdrawal validation' => sub {

    $params[1]->{args}->{verify_email} = $client->email;
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token 2');
    $params[1]->{token} = $token;

    my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
    my %dummy_error  = ('error' => 'dummy');
    $mock_utility->mock(cashier_validation => sub { \%dummy_error });

    for my $type (qw(payment_withdraw paymentagent_withdraw)) {
        $params[1]->{args}->{type} = $type;
        is $rpc_ct->call_ok(@params)->has_no_system_error->result, \%dummy_error, $type . ' has withdrawal validation';
    }

    for my $type (qw(account_opening reset_password)) {
        $params[1]->{args}->{type} = $type;
        $rpc_ct->call_ok(@params)
            ->has_no_system_error->has_no_error->result_is_deeply($expected_result, $type . ' does not have withdrawal validation');
    }
};

subtest 'bom-rules validation' => sub {
    my $emitted_events;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->mock(emit => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

    my $mock_rules = Test::MockModule->new('BOM::Rules::Engine');
    $mock_rules->mock(apply_rules => sub { {'error' => 'dummy'} });

    $params[1]->{args}->{verify_email} = $client->email;
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token 3');
    $params[1]->{token} = $token;
    undef $emitted_events;

    for my $type (qw( paymentagent_withdraw payment_withdraw)) {
        $params[1]->{args}->{type} = $type;
        my $res = $rpc_ct->call_ok(@params)->has_no_system_error->result;
        ok exists $res->{error}, $type . ' has bom-rules validation';
    }

    is $emitted_events, undef, 'no events emitted';

    for my $type (qw(account_opening reset_password)) {
        $params[1]->{args}->{type} = $type;
        $rpc_ct->call_ok(@params)
            ->has_no_system_error->has_no_error->result_is_deeply($expected_result, $type . ' does not have bom-rules validation');
    }
};

subtest 'Reset password for not exists user' => sub {
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { @emitted = @_ };

    $params[1]->{args}->{verify_email} = $email;
    $params[1]->{args}->{type}         = 'reset_password';
    $params[1]->{server_name}          = 'deriv.com';
    $params[1]->{link}                 = 'deriv.com/some_url';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");
    is($emitted[0], 'verify_email_closed_account_reset_password', 'type=verify_email_closed_account_reset_password');
    ok($emitted[1]->{properties}, 'Properties are set');
    is($emitted[1]->{properties}{email}, lc $params[1]->{args}->{verify_email}, 'email is set');
    is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
};

subtest 'Affiliate self tagging requests' => sub {
    my @emitted;
    my $myaffiliate_email = 'dummy@binary.com';
    no warnings 'redefine';

    my $mock_verify_email = Test::MockModule->new("BOM::RPC::v3::VerifyEmail::Functions");
    $mock_verify_email->redefine(create_client => sub { return "OK"; });

    my $myaffiliate_obj = {
        "TOKEN" => {
            "USER_ID" => "",
            "USER"    => {"EMAIL" => $myaffiliate_email}}};
    my $mock_myaffiliates = Test::MockModule->new('BOM::MyAffiliates');
    $mock_myaffiliates->redefine(get_affiliate_details => sub { return $myaffiliate_obj });

    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->redefine(emit => sub { push @emitted, $_[1] if $_[0] eq 'self_tagging_affiliates' });

    $params[1]->{args}->{verify_email}                      = 'dummy@binary.com';
    $params[1]->{args}->{type}                              = 'account_opening';
    $params[1]->{args}->{url_parameters}->{utm_medium}      = 'affiliate';
    $params[1]->{server_name}                               = 'deriv.com';
    $params[1]->{link}                                      = 'deriv.com/some_url';
    $params[1]->{args}->{url_parameters}->{utm_campaign}    = 'MyAffiliates';
    $params[1]->{args}->{url_parameters}->{affiliate_token} = 'sampletoken';

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    is scalar @emitted, 1, "self_tagging_affiliates event is triggered";

    $mock_events->unmock_all();
    $mock_myaffiliates->unmock_all();
    $mock_verify_email->unmock_all();
};

subtest 'Reset Password request with an unofficial app_id' => sub {
    mailbox_clear();
    my $oauth = BOM::Database::Model::OAuth->new;
    my $app1  = $oauth->create_app({
        name         => 'Test App',
        user_id      => 1,
        scopes       => ['read', 'admin', 'trade', 'payments'],
        redirect_uri => 'https://www.example.com/',
    });
    $params[1]->{args}->{verify_email}                 = $client->email;
    $params[1]->{args}->{type}                         = 'reset_password';
    $params[1]->{args}->{url_parameters}->{utm_medium} = 'email';
    $params[1]->{server_name}                          = 'binary.com';
    $params[1]->{link}                                 = 'deriv.com/some_url';
    $params[1]->{source}                               = $app1->{app_id};

    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('PermissionDenied', 'If the app is unofficial app')
        ->error_message_is('Permission denied.');
};

subtest 'Request Email request with an unofficial app_id' => sub {
    mailbox_clear();

    my $oauth = BOM::Database::Model::OAuth->new;
    my $app1  = $oauth->create_app({
        name         => 'Test App',
        user_id      => 1,
        scopes       => ['read', 'admin', 'trade', 'payments'],
        redirect_uri => 'https://www.example.com/',
    });
    $params[1]->{args}->{verify_email}                 = $client->email;
    $params[1]->{args}->{type}                         = 'request_email';
    $params[1]->{args}->{url_parameters}->{utm_medium} = 'email';
    $params[1]->{server_name}                          = 'binary.com';
    $params[1]->{link}                                 = 'deriv.com/some_url';
    $params[1]->{source}                               = $app1->{app_id};

    $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('PermissionDenied', 'If the app is unofficial app')
        ->error_message_is('Permission denied.');

};

done_testing();
