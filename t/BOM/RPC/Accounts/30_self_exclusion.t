use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Email::Address::UseXS;
use BOM::Test::Email qw(:no_event);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::User;
use BOM::User::Password;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::Accounts;
use Test::BOM::RPC::QueueClient;

BOM::Test::Helper::Token::cleanup_redis_tokens();

my $mock_lc = Test::MockModule->new('LandingCompany');

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

my $test_loginid = $test_client->loginid;
my $user         = BOM::User->create(
    email         => $email,
    password      => $hash_pwd,
    email_consent => 1
);
$user->add_client($test_client);
$user->add_client($test_client_vr);

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $email_mlt_mf    = 'mltmf@binary.com';
my $test_client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    residence   => 'at',
});
$test_client_mlt->email($email_mlt_mf);
$test_client_mlt->set_default_account('EUR');
$test_client_mlt->save;

my $test_client_mlt_loginid = $test_client_mlt->loginid;

my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    residence   => 'at',
});
$test_client_mf->email($email_mlt_mf);
$test_client_mf->save;

my $user_mlt_mf = BOM::User->create(
    email         => $email_mlt_mf,
    password      => $hash_pwd,
    email_consent => 1
);
$user_mlt_mf->add_client($test_client_mlt);
$user_mlt_mf->add_client($test_client_mf);

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
$test_client_cr->email('cr3@binary.com');
$test_client_cr->save;
my $user_cr = BOM::User->create(
    email    => 'sample3@binary.com',
    password => $hash_pwd
);
$user_cr->add_client($test_client_cr);

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_loginid, 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_vr       = $m->create_token($test_client_vr->loginid, 'test token');
my $token_mlt      = $m->create_token($test_client_mlt->loginid, 'test token');

my $token_cr = $m->create_token($test_client_cr->loginid, 'test token');

my $c = Test::BOM::RPC::QueueClient->new();

my @field_names =
    qw/max_balance max_turnover max_losses max_7day_turnover max_7day_losses max_30day_losses max_30day_turnover max_open_bets session_duration_limit/;

my %arg_values = (
    max_open_bets => $test_client_cr->get_limit_for_open_positions,
    timeout_until => Date::Utility->new->plus_time_interval('1d')->epoch,
    exclude_until => Date::Utility->new->plus_time_interval('7mo')->date,
);

my $method = 'set_self_exclusion';
subtest 'get and set self_exclusion' => sub {
    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');

    my $emitted;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->mock(
        'emit',
        sub {
            my ($type, $data) = @_;
            $emitted->{$type} = $data;
        });

    $mock_lc->mock('deposit_limit_enabled' => sub { return 1 });

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

    my $params = {
        token => $token_vr,
        args  => {}};
    is($c->tcall($method, $params)->{error}{message_to_client}, "Permission denied.", 'vr client cannot set exclusion');

    $params->{token} = $token;

    is($c->tcall($method, $params)->{error}{message_to_client}, "Please provide at least one self-exclusion setting.", "need one exclusion");

    $params->{args} = {
        set_self_exclusion => 1,
        max_balance        => 10000,
        max_open_bets      => 50,
        max_turnover       => undef,    # null should be OK to pass
        max_7day_losses    => 0,        # 0 is ok to pass but not saved
        max_deposit        => 10,
        max_7day_deposit   => 10,
        max_30day_deposit  => 10,
    };

    # Test for Maximum bets
    $params->{args}->{max_open_bets} = 120;

    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Please enter a number between 1 and 100.",
            'details'           => 'max_open_bets',
            'code'              => 'SetSelfExclusionError'
        });

    $params->{args}->{max_open_bets} = 50;

    # Test for Maximum balance
    $params->{args}->{max_balance} = 399999;
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Please enter a number between 0 and 300000.",
            'details'           => 'max_balance',
            'code'              => 'SetSelfExclusionError'
        });

    $params->{args}->{max_balance} = 10000;

    is($c->tcall($method, $params)->{status}, 1, "update self_exclusion ok");

    $params->{args}{max_balance} = 9999.999;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Input validation failed: max_balance.',
        'don\'t allow more than two decimals in max balance for this client'
    );
    $params->{args}{max_balance} = 9999.99;
    is($c->tcall($method, $params)->{status}, 1, 'allow two decimals in max balance');

    #test for deposit limits
    for (qw(max_deposit max_7day_deposit max_30day_deposit)) {
        $params->{args}->{$_} = 11;
        is_deeply(
            $c->tcall($method, $params)->{error},
            {
                'message_to_client' => "Please enter a number between 0 and 10.",
                'details'           => $_,
                'code'              => 'SetSelfExclusionError'
            });
        $params->{args}->{$_} = 10;
    }

    delete $params->{args};
    is_deeply(
        $c->tcall('get_self_exclusion', $params),
        {
            'max_open_bets'   => '50',
            'max_balance'     => '9999.99',
            max_deposit       => 10,
            max_7day_deposit  => 10,
            max_30day_deposit => 10,
        },
        'get self_exclusion ok'
    );

    # don't send previous required fields, should be okay
    $params->{args} = {
        set_self_exclusion => 1,
        max_30day_turnover => 100000
    };
    is($c->tcall($method, $params)->{status}, 1, "update self_exclusion ok");

    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440 * 42 + 1,
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Session duration limit cannot be more than 6 weeks.",
            'details'           => 'session_duration_limit',
            'code'              => 'SetSelfExclusionError'
        });
    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        exclude_until          => '2010-01-01'
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Exclude time must be after today.",
            'details'           => 'exclude_until',
            'code'              => 'SetSelfExclusionError'
        });
    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        exclude_until          => Date::Utility->new->plus_time_interval('3mo')->date_yyyymmdd
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Exclude time cannot be less than 6 months.",
            'details'           => 'exclude_until',
            'code'              => 'SetSelfExclusionError'
        });

    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        exclude_until          => Date::Utility->new->plus_time_interval('6y')->date_yyyymmdd
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Exclude time cannot be for more than five years.",
            'details'           => 'exclude_until',
            'code'              => 'SetSelfExclusionError'
        });

    # timeout_until
    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        timeout_until          => time() - 86400,
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Timeout time must be greater than current time.",
            'details'           => 'timeout_until',
            'code'              => 'SetSelfExclusionError'
        });

    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9999,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        timeout_until          => time() + 86400 * 7 * 10,    # max is 6 weeks
    };
    is_deeply(
        $c->tcall($method, $params)->{error},
        {
            'message_to_client' => "Timeout time cannot be more than 6 weeks.",
            'details'           => 'timeout_until',
            'code'              => 'SetSelfExclusionError'
        });

    mailbox_clear();
    my $exclude_until = Date::Utility->new->plus_time_interval('7mo')->date_yyyymmdd;
    my $timeout_until = Date::Utility->new->plus_time_interval('1d');
    $params->{args} = {
        set_self_exclusion     => 1,
        max_balance            => 9998,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        exclude_until          => $exclude_until,
        timeout_until          => $timeout_until->epoch,
    };

    is($c->tcall($method, $params)->{status}, 1, 'update self_exclusion ok');
    my $msg = mailbox_search(
        email   => 'compliance@deriv.com',
        subject => qr/Client $test_loginid set self-exclusion limits/,    # debug => 1,
    );
    ok($msg, "msg sent to marketing and compliance email");
    is_deeply($msg->{to}, ['compliance@deriv.com'], "msg sent to marketing and compliance email");
    like($msg->{body}, qr/.*Exclude from website until/s, 'email content is ok');
    ok($emitted->{self_exclude}, 'self_exclude event emitted');

    like(
        $c->tcall($method, $params)->{error}->{message_to_client},
        qr/Sorry, but you have self-excluded yourself from the website until/,
        'Self excluded client cannot access set self exclusion'
    );

    delete $params->{args};
    ok($c->tcall('get_self_exclusion', $params), 'Get response even if client is self excluded');

    $test_client->load();
    my $self_excl = $test_client->get_self_exclusion;
    is $self_excl->max_balance, 9998, 'set correct in db';
    is $self_excl->exclude_until, $exclude_until . 'T00:00:00', 'exclude_until in db is right';
    is $self_excl->timeout_until, $timeout_until->epoch, 'timeout_until is right';
    is $self_excl->session_duration_limit, 1440, 'all good';

    $mock_lc->unmock_all;

    ## Section: Check self-exclusion notification emails for compliance, related to
    ##  clients under Deriv (Europe) Limited, are sent under correct circumstances.
    mailbox_clear();

    ## Set some limits, and no email should be sent, because no MT5 account has
    ##   been opened yet.
    $params->{token} = $token_mlt;
    ##  clients under Deriv (Europe) Limited, are sent under correct circumstances.

    ## Set some limits, and no email should be sent, because no MT5 account has
    ##   been opened yet.
    $params->{token} = $token_mlt;
    $params->{args}  = {
        set_self_exclusion     => 1,
        max_balance            => 9998,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
    };
    delete $emitted->{self_exclude};
    is($c->tcall($method, $params)->{status}, 1, 'update self_exclusion ok');
    $msg = mailbox_search(
        email   => 'compliance@deriv.com',
        subject => qr/Client $test_client_mlt_loginid set self-exclusion limits/
    );
    ok(!$msg, 'No email for MLT client limits without MT5 accounts');
    is($emitted->{self_exclude}, undef, 'self_exclude event not emitted');

    my $update_mt5_params = {
        language   => 'EN',
        token      => $token_mlt,
        client_ip  => '127.0.0.1',
        user_agent => 'agent',
        args       => {
            address_line_1         => 'address line 1',
            address_line_2         => 'address line 2',
            address_city           => 'address city',
            address_state          => 'BA',
            place_of_birth         => 'de',
            account_opening_reason => 'Income Earning',
        }};
    is($c->tcall('set_settings', $update_mt5_params)->{status}, 1, 'update successfully');

    my %ACCOUNTS = %Test::BOM::RPC::Accounts::MT5_ACCOUNTS;
    my %DETAILS  = %Test::BOM::RPC::Accounts::ACCOUNT_DETAILS;
    @BOM::MT5::User::Async::MT5_WRAPPER_COMMAND = ($^X, 't/lib/mock_binary_mt5.pl');

    my $mt5_params = {
        language => 'EN',
        token    => $token_mlt,
        args     => {
            account_type   => 'gaming',
            country        => 'mt',
            email          => $DETAILS{email},
            name           => $DETAILS{name},
            investPassword => 'Abcd1234',
            mainPassword   => $DETAILS{password}{main},
            leverage       => 100,
        }};

    my $mt5_loginid = $c->tcall('mt5_new_account', $mt5_params)->{login};
    is($mt5_loginid, 'MTR' . $ACCOUNTS{'real01\synthetic\malta_std_eur'}, 'MT5 loginid is correct: ' . $mt5_loginid);

    ## Verify an email was sent after opening an MT5 account, since user has
    ##  limits currently in place.
    $msg = mailbox_search(
        email   => 'compliance@deriv.com',
        subject => qr/Client $test_client_mlt_loginid set self-exclusion limits/
    );
    ok($msg, 'Email for MLT client limits with MT5 accounts');
    is_deeply($msg->{to}, ['compliance@deriv.com', 'x-acc@deriv.com'], 'email to address ok');
    like($msg->{body}, qr/$mt5_loginid/, 'email content is ok');

    ## Set some limits again, and another email should be sent to compliance listing
    ##  the new limitations since an MT5 account is open.
    mailbox_clear();
    is($c->tcall($method, $params)->{status}, 1, 'update self_exclusion ok');
    $msg = mailbox_search(
        email   => 'compliance@deriv.com',
        subject => qr/Client $test_client_mlt_loginid set self-exclusion limits/
    );
    ok($msg, 'Email for MLT client limits with MT5 accounts');
    is_deeply($msg->{to}, ['compliance@deriv.com', 'x-acc@deriv.com'], 'email to address ok');
    like($msg->{body}, qr/$mt5_loginid/, 'email content is ok');
    delete $params->{args};
    delete $emitted->{self_exclude};
    $params->{token} = $token_cr;
    $params->{args}  = {
        set_self_exclusion     => 1,
        max_balance            => 9998,
        max_turnover           => 1000,
        max_open_bets          => 50,
        session_duration_limit => 1440,
        exclude_until          => $exclude_until,
        timeout_until          => $timeout_until->epoch,
    };
    is($c->tcall($method, $params)->{status}, 1,     'update self_exclusion ok');
    is($emitted->{self_exclude},              undef, 'self_exclude event not emitted because email_consent is not set for user');
};

subtest 'deposit limits disabled' => sub {
    $test_client->set_exclusion->max_deposit_daily(undef);
    $test_client->set_exclusion->max_deposit_7day(undef);
    $test_client->set_exclusion->max_deposit_30day(undef);
    $test_client->set_exclusion->exclude_until(undef);
    $test_client->set_exclusion->timeout_until(undef);
    $test_client->save();

    my $params = {
        token => $token,
    };

    for my $name (qw(max_deposit max_7day_deposit max_30day_deposit)) {
        $mock_lc->mock('deposit_limit_enabled' => sub { return 0 });

        $params->{args}->{$name} = 100;

        is_deeply(
            $c->tcall($method, $params)->{error},
            {
                'message_to_client' => "Sorry, but setting your maximum deposit limit is unavailable in your country.",
                'details'           => $name,
                'code'              => 'SetSelfExclusionError'
            },
            'Correct error result if deposit limits are disabled'
        );

        $mock_lc->mock('deposit_limit_enabled' => sub { return 1 });

        my $result = $c->tcall($method, $params);
        is $result->{error}, undef, 'No error if deposit limits are enabled';

        delete $params->{args}->{$name};
    }

    $mock_lc->mock('deposit_limit_enabled' => sub { return 0 });
    delete $params->{args};
    is $c->tcall('get_self_exclusion', $params)->{max_deposit}, undef, 'No deposit limits are returned if they are disabled';

    $mock_lc->mock('deposit_limit_enabled' => sub { return 1 });
    is_deeply [$c->tcall('get_self_exclusion', $params)->@{qw(max_deposit max_7day_deposit max_30day_deposit)}],
        [100, 100, 100],
        'Correct limits when deposit limits are enabled';

    $mock_lc->unmock('deposit_limit_enabled');
};

subtest 'Set self-exclusion - CR clients' => sub {
    my $method = 'set_self_exclusion';
    my $params = {
        token => $token_cr,
        args  => {},
    };
    my $get_params = {
        token => $token_cr,
    };

    #clear self-exclusions
    $test_client_cr->set_exclusion->exclude_until(undef);
    $test_client_cr->set_exclusion->timeout_until(undef);
    $test_client_cr->save;

    for my $field (qw/exclude_until timeout_until/) {
        my $value = $arg_values{$field};
        $params->{args}->{$field} = $value;
        is $c->tcall($method, $params)->{status}, 1, "RPC called successfully with value $value - $field";
        is $c->tcall('get_self_exclusion', $get_params)->{$field}, $value, "get_self_exclusion returns the same value $value - $field";

        like $c->tcall($method, $params)->{error}->{message_to_client}, qr/Sorry, but you have self-excluded yourself from the website until/,
            "set_self_exclusion fails if client is excluded - $field";
        is $c->tcall('get_self_exclusion', $get_params)->{$field}, $value, "get_self_exclusion returns the same value $value - $field";

        # remove exclude_until to proceed with tests
        $test_client_cr->set_exclusion->$field(undef);
        $test_client_cr->save;

        delete $params->{args}->{$field};
    }

    for my $field (@field_names) {
        $params->{args}->{$field} = 'abcd';
        is_deeply $c->tcall($method, $params)->{error},
            {
            code              => 'InputValidationFailed',
            details           => {$field => 'Please input a valid number.'},
            message_to_client => "Input validation failed: $field."
            },
            'Correct error for invalid number';

        $params->{args}->{$field} = -1;
        is_deeply $c->tcall($method, $params)->{error},
            {
            code              => 'InputValidationFailed',
            details           => {$field => 'Please input a valid number.'},
            message_to_client => "Input validation failed: $field."
            },
            "Correct error for negative value - $field";

        my $base_value = $arg_values{$field} // 1001;
        for my $value ($base_value, $base_value - 1, $base_value + 1, 0) {
            $params->{args}->{$field} = $value;
            is $c->tcall($method, $params)->{status}, 1, "RPC called successfully with value $value - $field";

            is $c->tcall('get_self_exclusion', $get_params)->{$field} // 0, $value, "get_self_exclusion returns the same value $value - $field";
        }
        delete $params->{args}->{$field};
    }
};

subtest 'Set self-exclusion - regulated landing companies' => sub {
    my $mock_lc = Test::MockModule->new('LandingCompany');
    $mock_lc->mock(is_eu => sub { return 1 });

    my $method = 'set_self_exclusion';
    my $params = {
        token => $token_cr,
        args  => {},
    };
    my $get_params = {
        token => $token_cr,
    };

    foreach my $field (@field_names) {
        my $value = $arg_values{$field} // 1001;

        $params->{args}->{$field} = $value;
        is $c->tcall($method, $params)->{status}, 1, "RPC called successfully with value $value - $field";
        is $c->tcall('get_self_exclusion', $get_params)->{$field} // 0, $value, "get_self_exclusion returns the same value $value - $field";

        my $value_minus = $value - 1;
        my $minimum     = $field =~ 'max_open_bets|session_duration_limit' ? 1 : 0;
        $params->{args}->{$field} = $value_minus;
        is $c->tcall($method, $params)->{status}, 1, "RPC called successfully with value minus one - $field";
        is $c->tcall('get_self_exclusion', $get_params)->{$field} // 0, $value_minus, "get_self_exclusion returns value $value_minus - $field";

        $params->{args}->{$field} = $value;

        is_deeply $c->tcall($method, $params)->{error},
            {
            code              => 'SetSelfExclusionError',
            details           => $field,
            message_to_client => "Please enter a number between $minimum and $value_minus."
            },
            "RPC fails if called with value $value again - $field";
        is $c->tcall('get_self_exclusion', $get_params)->{$field} // 0, $value_minus, "get_self_exclusion returns the previous value - $field";

        delete $params->{args}->{$field};
    }

    for my $field (qw/exclude_until timeout_until/) {
        my $value = $arg_values{$field};
        $params->{args}->{$field} = $value;
        is $c->tcall($method, $params)->{status}, 1, "RPC called successfully with value $value - $field";
        is $c->tcall('get_self_exclusion', $get_params)->{$field}, $value, "get_self_exclusion returns the same value $value - $field";

        like $c->tcall($method, $params)->{error}->{message_to_client}, qr/Sorry, but you have self-excluded yourself from the website until/,
            "set_self_exclusion fails if client is excluded - $field";
        is $c->tcall('get_self_exclusion', $get_params)->{$field}, $value, "get_self_exclusion returns the same value $value - $field";

        # remove exclude_until to proceed with tests
        $test_client_cr->set_exclusion->$field(undef);
        $test_client_cr->save;

        delete $params->{args}->{$field};
    }

    $mock_lc->unmock_all;
};

done_testing();
