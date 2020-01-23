use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::BOM::RPC::Client;
use Email::Address::UseXS;
use BOM::Test::Email qw(:no_event);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::User;
use BOM::User::Password;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::Accounts;

BOM::Test::Helper::Token::cleanup_redis_tokens();

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
    email    => $email,
    password => $hash_pwd
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
    email    => $email_mlt_mf,
    password => $hash_pwd
);
$user_mlt_mf->add_client($test_client_mlt);
$user_mlt_mf->add_client($test_client_mf);

my $m              = BOM::Platform::Token::API->new;
my $token          = $m->create_token($test_loginid, 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_vr       = $m->create_token($test_client_vr->loginid, 'test token');
my $token_mlt      = $m->create_token($test_client_mlt->loginid, 'test token');

my $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
my $c = Test::BOM::RPC::Client->new(ua => $t->app->ua);

my $method = 'set_self_exclusion';
subtest 'get and set self_exclusion' => sub {
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

    delete $params->{args};
    is_deeply(
        $c->tcall('get_self_exclusion', $params),
        {
            'max_open_bets' => '50',
            'max_balance'   => '9999.99'
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
        email   => 'compliance@binary.com',
        subject => qr/Client $test_loginid set self-exclusion limits/,    # debug => 1,
    );
    ok($msg, "msg sent to marketing and compliance email");
    is_deeply($msg->{to}, ['compliance@binary.com', 'marketing@binary.com'], "msg sent to marketing and compliance email");
    like($msg->{body}, qr/.*Exclude from website until/s, 'email content is ok');

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

    ## Section: Check self-exclusion notification emails for compliance, related to
    ##  clients under Binary (Europe) Limited, are sent under correct circumstances.
    mailbox_clear();

    ## Set some limits, and no email should be sent, because no MT5 account has
    ##   been opened yet.
    $params->{token} = $token_mlt;
    ##  clients under Binary (Europe) Limited, are sent under correct circumstances.

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
    is($c->tcall($method, $params)->{status}, 1, 'update self_exclusion ok');
    $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/Client $test_client_mlt_loginid set self-exclusion limits/
    );
    ok(!$msg, 'No email for MLT client limits without MT5 accounts');

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
    is($mt5_loginid, $ACCOUNTS{'real\malta'}, 'MT5 loginid is correct: ' . $mt5_loginid);

    ## Verify an email was sent after opening an MT5 account, since user has
    ##  limits currently in place.
    $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/Client $test_client_mlt_loginid set self-exclusion limits/
    );
    ok($msg, 'Email for MLT client limits with MT5 accounts');
    is_deeply($msg->{to}, ['compliance@binary.com', 'marketing@binary.com', 'x-acc@binary.com'], 'email to address ok');
    like($msg->{body}, qr/MT$mt5_loginid/, 'email content is ok');

    ## Set some limits again, and another email should be sent to compliance listing
    ##  the new limitations since an MT5 account is open.
    mailbox_clear();
    is($c->tcall($method, $params)->{status}, 1, 'update self_exclusion ok');
    $msg = mailbox_search(
        email   => 'compliance@binary.com',
        subject => qr/Client $test_client_mlt_loginid set self-exclusion limits/
    );
    ok($msg, 'Email for MLT client limits with MT5 accounts');
    is_deeply($msg->{to}, ['compliance@binary.com', 'marketing@binary.com', 'x-acc@binary.com'], 'email to address ok');
    like($msg->{body}, qr/MT$mt5_loginid/, 'email content is ok');
};

done_testing();
