use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::Fatal    qw(lives_ok);
use Test::Warnings qw(warning);
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
use BOM::RPC::v3::VerifyEmail::Functions;
use BOM::Test::RPC::QueueClient;
use utf8;

$ENV{EMAIL_SENDER_TRANSPORT} = 'Test';
my ($user, $client, $email);
my $rpc_ct;
my $method = 'verify_email';

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
            broker_code    => 'CR',
            binary_user_id => $user->id,
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

subtest 'Email verification for user that signed up during optional email verification flow' => sub {
    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { push @emitted, @_ };

    my $type = 'account_verification';

    $params[1]->{args}                                 = {};
    $params[1]->{args}->{type}                         = $type;
    $params[1]->{args}->{url_parameters}->{utm_medium} = 'email';
    $params[1]->{server_name}                          = 'deriv.com';
    $params[1]->{link}                                 = 'deriv.com/some_url';

    for my $feature_flag (1, 0) {
        # Regardless of feature flag status, one can always ask for account_verification
        BOM::Config::Runtime->instance->app_config->email_verification->suspend->virtual_accounts($feature_flag);

        my $email = 'account_verification' . $feature_flag . rand(999) . '@deriv.com';
        $params[1]->{args}->{verify_email} = $email;

        subtest 'Email verification for non existing user' => sub {
            $rpc_ct->call_ok(@params)
                ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");
            is scalar @emitted, 0, 'no email as user does not exist';
            @emitted = ();
        };

        subtest 'Email verification unverified existing user' => sub {
            my $args = {
                details => {
                    email           => $email,
                    client_password => 'secret_pwd',
                    residence       => 'au',
                    account_type    => 'binary',
                    email_verified  => 0,
                },
            };
            my $acc = BOM::Platform::Account::Virtual::create_account($args);
            my ($vr_client, $user) = ($acc->{client}, $acc->{user});

            ok !$user->email_verified, 'user is not email verified';

            $rpc_ct->call_ok(@params)
                ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

            is($emitted[0], 'account_verification', 'type=account_verification');
            is $emitted[1]->{email}, $params[1]->{args}->{verify_email}, 'email is set';
            is $emitted[1]->{verification_url},
                'https://www.binary.com/en/redirect.html?action=verify_account&lang=EN&code=' . $emitted[1]->{code} . '&utm_medium=email',
                'verification_url is set';
            is $emitted[1]->{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
            @emitted = ();
        };

        subtest 'Email verification already verified existing user' => sub {
            my $verified_email = 'verified_' . $email;
            $params[1]->{args}->{verify_email} = $verified_email;

            my $args = {
                details => {
                    email           => $verified_email,
                    client_password => 'secret_pwd',
                    residence       => 'au',
                    account_type    => 'binary',
                    email_verified  => 1,
                },
            };
            my $acc = BOM::Platform::Account::Virtual::create_account($args);
            my ($vr_client, $user) = ($acc->{client}, $acc->{user});

            ok $user->email_verified, 'user is already email verified';

            $rpc_ct->call_ok(@params)
                ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

            is scalar @emitted, 0, 'no email as user\'s email is already verified';
            @emitted = ();
        };
    }
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
        $mock_pa->mock(cashier_withdrawable_balance => sub { 0 });

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

    subtest 'empty loginids, existing user' => sub {
        my @loginids  = ();
        my @doggy_bag = ();

        my $func_mock = Test::MockModule->new('BOM::RPC::v3::VerifyEmail::Functions');
        $func_mock->mock(
            'stats_inc',
            sub {
                push @doggy_bag, @_;
            });

        my $user_mock = Test::MockModule->new('BOM::User');
        $user_mock->mock(
            'bom_loginids',
            sub {
                return @loginids;
            });

        my $endpoints = [qw/verify_email/];
        my $types     = [qw/account_opening reset_password foobar/];

        # for account closed sort of emails
        my $event_mappings = {
            account_opening => 'verify_email_closed_account_account_opening',
            reset_password  => 'verify_email_closed_account_reset_password',
            foobar          => 'verify_email_closed_account_other',
        };

        # special outcome when the user exists but there is no loginid attached
        my $event_outcome_when_not_closed = {
            account_opening => {
                emissions => [
                    'account_opening_new',
                    {
                        code             => re('.*'),
                        email            => re('.*'),
                        verification_url => re('.*'),
                        live_chat_url    => re('.*'),
                    }
                ],
                doggy => [
                    'bom_rpc.verify_email.user_with_no_loginid',
                    {'tags' => [re('user:\d+'), 'type:account_opening',]}

                ],
            },
            reset_password => {
                emissions => [],
                doggy     => [
                    'bom_rpc.verify_email.user_with_no_loginid',
                    {'tags' => [re('user:\d+'), 'type:reset_password',]}

                ],
            },
            foobar => {
                emissions => [],
                doggy     => [
                    'bom_rpc.verify_email.user_with_no_loginid',
                    {'tags' => [re('user:\d+'), 'type:foobar',]}

                ],
                exception => 'unknown type foobar',
            },
        };

        for my $endpoint ($endpoints->@*) {
            subtest $endpoint => sub {
                for my $type ($types->@*) {
                    subtest $type => sub {
                        @emitted = ();

                        my $password = 'jskjd8292922';
                        my $hash_pwd = BOM::User::Password::hashpw($password);

                        my $email = $endpoint . '+' . $type . rand(999) . '@binary.com';

                        my $user = BOM::User->create(
                            email    => $email,
                            password => $hash_pwd
                        );

                        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                            broker_code => 'CR',
                        });

                        $client->status->set('disabled', 'test', 'test');

                        $client->account('USD');
                        $user->add_client($client);

                        my $params = {
                            language => 'EN',
                            country  => 'ru',
                            source   => 1,
                            args     => {
                                $endpoint   => $email,
                                type        => $type,
                                server_name => 'binary.com',
                                link        => 'binary.com/some_url',
                            },
                        };

                        @doggy_bag = ();
                        @loginids  = ($client->loginid);

                        $rpc_ct->call_ok($endpoint, $params)->has_no_system_error->has_no_error('no error on closed account')
                            ->result_is_deeply($expected_result, 'It always should return 1, so not to leak client\'s email');

                        cmp_deeply [@emitted],
                            [
                            $event_mappings->{$type},
                            {
                                loginid    => shift @loginids,
                                properties => {
                                    language      => 'EN',
                                    live_chat_url => 'https://www.binary.com/en/contact.html?is_livechat_open=true',
                                    email         => $email,
                                    type          => $type,
                                },
                            }
                            ],
                            'Expected emissions, closed account';
                        cmp_deeply [@doggy_bag], [], 'No stats_inc as the user has loginids';

                        @doggy_bag = ();
                        @loginids  = ();
                        @emitted   = ();

                        if (my $exception = $event_outcome_when_not_closed->{$type}->{exception}) {
                            my $warning = warning {
                                $rpc_ct->call_ok($endpoint, $params)
                                    ->has_no_system_error->has_error->error_code_is('InternalServerError', 'unknown type')
                                    ->error_message_is('Sorry, an error occurred while processing your request.');
                            };

                            ok $warning =~ qr/$exception/, $exception;
                        } else {
                            $rpc_ct->call_ok($endpoint, $params)->has_no_system_error->has_no_error('no error for empty loginids, existing user')
                                ->result_is_deeply($expected_result, 'It always should return 1, so not to leak client\'s email');
                        }

                        cmp_deeply [@emitted],   $event_outcome_when_not_closed->{$type}->{emissions}, 'Expected emissions, sign up email';
                        cmp_deeply [@doggy_bag], $event_outcome_when_not_closed->{$type}->{doggy},     'Expected datadog';

                        @doggy_bag = ();
                        @loginids  = ();
                        @emitted   = ();
                        $client->status->clear_disabled;

                        if (my $exception = $event_outcome_when_not_closed->{$type}->{exception}) {
                            my $warning = warning {
                                $rpc_ct->call_ok($endpoint, $params)
                                    ->has_no_system_error->has_error->error_code_is('InternalServerError', 'unknown type')
                                    ->error_message_is('Sorry, an error occurred while processing your request.');
                            };

                            ok $warning =~ qr/$exception/, $exception;
                        } else {
                            $rpc_ct->call_ok($endpoint, $params)
                                ->has_no_system_error->has_no_error('no error for empty loginids and disabled orphan, existing user')
                                ->result_is_deeply($expected_result, 'It always should return 1, so not to leak client\'s email');
                        }
                        cmp_deeply [@emitted], $event_outcome_when_not_closed->{$type}->{emissions}, 'Expected emissions, sign up email';
                    };
                }
            };
        }

        $user_mock->unmock_all;
        $func_mock->unmock_all;
    };

    $client->status->clear_disabled;
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

    my $mock_rules          = Test::MockModule->new('BOM::Rules::Engine');
    my $apply_rules_invoked = 0;
    $mock_rules->mock(apply_rules => sub { $apply_rules_invoked = 1; die {error_code => 'dummy'} });

    $params[1]->{args}->{verify_email} = $client->email;
    $params[1]->{server_name}          = 'binary.com';
    $params[1]->{link}                 = 'binary.com/some_url';

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token 3');
    $params[1]->{token} = $token;
    undef $emitted_events;

    for my $type (qw( paymentagent_withdraw )) {
        $params[1]->{args}->{type} = $type;
        my $res = $rpc_ct->call_ok(@params)->has_no_system_error->result;
        ok $apply_rules_invoked, $type . ' has bom-rules validation';
        $apply_rules_invoked = 0;
    }

    is $emitted_events, undef, 'no events emitted';

    for my $type (qw(payment_withdraw account_opening reset_password)) {
        $params[1]->{args}->{type} = $type;
        $rpc_ct->call_ok(@params)
            ->has_no_system_error->has_no_error->result_is_deeply($expected_result, $type . ' does not have bom-rules validation');
    }
};

subtest 'Reset password for not existing user' => sub {
    $client->status->set('disabled', 1, 'test disabled');

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

    $client->status->clear_disabled;
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

subtest 'Functions.pm' => sub {
    subtest 'user closed' => sub {
        my $verify_email_object = BOM::RPC::v3::VerifyEmail::Functions->new(
            args => {
                verify_email   => $user->email,
                type           => 'account_opening',
                url_parameters => {},
            });

        my $user_mock = Test::MockModule->new('BOM::User');
        my @loginids  = ($client->loginid);

        $client->status->setnx('disabled', 'test', 'test');

        $user_mock->mock(
            'bom_loginids',
            sub {
                return @loginids;
            });

        ok !$verify_email_object->is_existing_user_closed, 'There is no user yet';

        $verify_email_object->create_existing_user();

        ok $verify_email_object->is_existing_user_closed, 'User is closed';

        # reload the statuses
        $client->status->clear_disabled;
        $verify_email_object->create_existing_user();

        ok !$verify_email_object->is_existing_user_closed, 'User is not closed';

        # make it closed again
        $client->status->setnx('disabled', 'test', 'test');
        $verify_email_object->create_existing_user();

        ok $verify_email_object->is_existing_user_closed, 'User is closed again';

        # empty loginids
        @loginids = ();
        ok !$verify_email_object->is_existing_user_closed, 'User is not closed';

        $user_mock->unmock_all;
    };

    subtest 'available loginid' => sub {
        my $verify_email_object = BOM::RPC::v3::VerifyEmail::Functions->new(
            args => {
                verify_email   => $user->email,
                type           => 'account_opening',
                url_parameters => {},
            });
        my $user_mock = Test::MockModule->new('BOM::User');
        my @loginids  = ($client->loginid);

        $user_mock->mock(
            'bom_loginids',
            sub {
                return @loginids;
            });

        $client->status->clear_disabled;
        ok !$verify_email_object->available_loginid, 'There is no user yet';

        $verify_email_object->create_existing_user();

        is $verify_email_object->available_loginid, $client->loginid, 'there is a loginid';

        # reload the statuses
        $client->status->setnx('disabled', 'test', 'test');
        $verify_email_object->create_existing_user();

        ok !$verify_email_object->available_loginid, 'not available loginid as they are disabled';

        # empty loginids
        @loginids = ();
        ok !$verify_email_object->available_loginid, 'no loginid available';

        $user_mock->unmock_all;
    };

};

subtest 'Phone Number Verification' => sub {
    my $expected_language;
    my $expected_verification_url;
    my $expected_live_chat_url;
    my $expected_code;
    my $increase_email_attempts;
    my $no_attempts_left;
    my $verified;
    my $expires_in = {};

    my $redis_mock = Test::MockModule->new('RedisDB');
    $redis_mock->mock(
        'expire',
        sub {
            my (undef, $key, $ttl) = @_;

            $expires_in->{$key} = $ttl;

            return $redis_mock->original('expire')->(@_);
        });

    my $pnv_mock = Test::MockModule->new('BOM::User::PhoneNumberVerification');
    $pnv_mock->mock(
        'email_blocked',
        sub {
            return $no_attempts_left;
        });
    $pnv_mock->mock(
        'verified',
        sub {
            return $verified;
        });

    $pnv_mock->mock(
        'increase_email_attempts',
        sub {
            $increase_email_attempts = 1;
            return $pnv_mock->original('increase_email_attempts')->(@_);
        });

    my $token_mock = Test::MockModule->new('BOM::Platform::Token');
    $token_mock->mock(
        'token',
        sub {
            $expected_code = $token_mock->original('token')->(@_);

            return $expected_code;
        });

    my $password = 'jskjd8292922';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    $email = 'pnv+' . rand(999) . '@binary.com';

    $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $client->first_name('Beautiful Robot');
    $client->account('USD');
    $client->email($email);
    $client->save;

    $user->add_client($client);

    my @emitted;
    no warnings 'redefine';
    local *BOM::Platform::Event::Emitter::emit = sub { push @emitted, @_ };
    $params[1]->{args}->{verify_email}                 = $email;
    $params[1]->{args}->{type}                         = 'phone_number_verification';
    $params[1]->{args}->{url_parameters}->{utm_medium} = 'email';
    $params[1]->{language}                             = 'EN';

    delete $params[1]->{server_name};
    delete $params[1]->{link};
    delete $params[1]->{source};
    delete $params[1]->{args}->{url_parameters};

    my $token = BOM::Platform::Token::API->new->create_token($client->loginid, 'test token');
    $params[1]->{token} = $token;
    @emitted            = ();
    $expires_in         = {};

    $rpc_ct->call_ok(@params)
        ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "It always should return 1, so not to leak client's email");

    $expected_language = 'EN';
    $expected_verification_url =
        "https://www.binary.com/en/redirect.html?action=phone_number_verification&lang=$expected_language&code=$expected_code";
    $expected_live_chat_url = 'https://www.binary.com/en/contact.html?is_livechat_open=true';
    ok $expected_code =~ /\d{6}/, '6 digit code';

    is $expires_in->{"VERIFICATION_TOKEN::$expected_code"}, 600, 'TTL of 10 minutes has been set';

    cmp_deeply [@emitted],
        [
        'phone_number_verification',
        {
            'loginid'    => $client->loginid,
            'properties' => {
                verification_url => $expected_verification_url,
                language         => $expected_language,
                live_chat_url    => $expected_live_chat_url,
                code             => $expected_code,
                email            => $client->email,
                first_name       => $client->first_name,
                broker_code      => $client->broker_code,
            }
        },
        ],
        'Expected emissions';

    subtest 'no attempts left' => sub {
        $no_attempts_left        = 1;
        $increase_email_attempts = undef;
        @emitted                 = ();
        $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('NoAttemptsLeft', 'Cannot send emails this quickly!')
            ->error_message_is('Please wait for some time before requesting another link');

        cmp_deeply [@emitted], [], 'No emissions';
        ok $increase_email_attempts, 'Increased email attempts';
    };

    subtest 'already verified' => sub {
        $verified                = 1;
        $increase_email_attempts = undef;
        @emitted                 = ();
        $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('AlreadyVerified', 'Already verified accounts need no apply!')
            ->error_message_is('This account is already phone number verified');

        cmp_deeply [@emitted], [], 'No emissions';
        ok !$increase_email_attempts, 'Not increasaed email attempts';
        $verified = undef;
    };

    subtest 'impersonating' => sub {
        my $utility_mock = Test::MockModule->new('BOM::RPC::v3::Utility');
        $utility_mock->mock(
            'is_impersonating_client',
            sub {
                return 1;
            });

        $no_attempts_left        = undef;
        $increase_email_attempts = undef;
        @emitted                 = ();
        $rpc_ct->call_ok(@params)->has_no_system_error->has_error->error_code_is('Permission Denied', 'Cannot use the feature while impersonating')
            ->error_message_is('You can not perform the phone number verification while impersonating an account');

        cmp_deeply [@emitted], [], 'No emissions';
        ok $increase_email_attempts, 'Increased email attempts';

        $utility_mock->unmock_all;
    };

    $pnv_mock->unmock_all;
    $token_mock->unmock_all;
};

subtest 'Account opening type token' => sub {
    my $params = {
        args => {
            verify_email   => 'test' . rand(999) . '.@binary.com',
            type           => 'account_opening',
            url_parameters => {},
        }};

    subtest 'is a 6 digit token' => sub {
        my $verify_email_object = BOM::RPC::v3::VerifyEmail::Functions->new(%{$params});
        $verify_email_object->create_token();
        my $token = $verify_email_object->{code};

        ok($token) =~ /\d{6}/, 'Expected a 6 digit token';
    };

    subtest 'is NOT a 6 digit token' => sub {
        $params->{args}->{type} = 'account_verification';

        my $verify_email_object = BOM::RPC::v3::VerifyEmail::Functions->new(%{$params});
        $verify_email_object->create_token();
        my $token = $verify_email_object->{code};

        ok($token) !~ /\d{6}/, 'Expected an 8 digit token';
    };
};

done_testing();
