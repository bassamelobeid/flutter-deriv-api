use strict;
use warnings;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use utf8;
use MojoX::JSON::RPC::Client;
use Data::Dumper;
use MIME::QuotedPrint qw(encode_qp);
use Encode qw(encode);
use BOM::Test::Email qw(get_email_by_address_subject clear_mailbox);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Database::Model::AccessToken;

package MojoX::JSON::RPC::Client;
use Data::Dumper;
use Test::Most;

sub tcall {
    my $self   = shift;
    my $method = shift;
    my $params = shift;
    my $r      = $self->call(
        "/$method",
        {
            id     => Data::UUID->new()->create_str(),
            method => $method,
            params => $params
        });
    ok($r->result,    'rpc response ok');
    ok(!$r->is_error, 'rpc response ok');
    if ($r->is_error) {
        diag(Dumper($r));
    }
    return $r->result;
}

package main;

################################################################################
# init db
################################################################################
my $email       = 'abc@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::System::Password::hashpw($password);
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
my $user         = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_loginid});
$user->add_loginid({loginid => $test_client_vr->loginid});
$user->save;
clear_mailbox();

my $m = BOM::Database::Model::AccessToken->new;
my $token = $m->create_token($test_loginid, 'test token');

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw(JPY USD JPY-USD);

my $now        = Date::Utility->new('2005-09-21 06:46:00');
my $underlying = BOM::Market::Underlying->new('R_50');
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => $now,
    });

################################################################################
# test
################################################################################

my $t = Test::Mojo->new('BOM::RPC');
my $c = MojoX::JSON::RPC::Client->new(ua => $t->app->ua);

my $method = 'payout_currencies';
subtest $method => sub {
    is_deeply($c->tcall($method, {client_loginid => 'CR0021'}), ['USD'], "will return client's currency");
    is_deeply($c->tcall($method, {}), [qw(USD EUR GBP AUD)], "will return legal currencies");
};

$method = 'landing_company';
subtest $method => sub {
    is_deeply(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                args     => {landing_company => 'nosuchcountry'}}
        ),
        {
            error => {
                message_to_client => '未知着陆公司。',
                code              => 'UnknownLandingCompany'
            }
        },
        "no such landing company"
    );
    my $ag_lc = $c->tcall($method, {args => {landing_company => 'ag'}});
    ok($ag_lc->{gaming_company},    "ag have gaming company");
    ok($ag_lc->{financial_company}, "ag have financial company");
    ok(!$c->tcall($method, {args => {landing_company => 'de'}})->{gaming_company},    "de have no gaming_company");
    ok(!$c->tcall($method, {args => {landing_company => 'hk'}})->{financial_company}, "hk have no financial_company");
};

$method = 'landing_company_details';
subtest $method => sub {
    is_deeply(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                args     => {landing_company_details => 'nosuchcountry'}}
        ),
        {
            error => {
                message_to_client => '未知着陆公司。',
                code              => 'UnknownLandingCompany'
            }
        },
        "no such landing company"
    );
    is($c->tcall($method, {args => {landing_company_details => 'costarica'}})->{name}, 'Binary (C.R.) S.A.', "details result ok");
};

$method = 'statement';
subtest $method => sub {
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => '12345'
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
    );
    ok(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => undef,
                client_loginid => 'CR0021'
            }
            )->{error},
        'no token error if token undef'
    );
    ok(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => $token,
                client_loginid => $test_loginid
            }
            )->{error},
        'no token error if token is valid'
    );
    is($c->tcall($method, {language => 'ZH_CN'})->{error}{message_to_client}, '请登陆。', 'need loginid');
    is(
        $c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                client_loginid => 'CR12345678'
            }
            )->{error}{message_to_client},
        '请登陆。',
        'need a valid client'
    );
    is($c->tcall($method, {client_loginid => 'CR0021'})->{count},      100, 'have 100 statements');
    is($c->tcall($method, {client_loginid => $test_loginid})->{count}, 0,   'have 0 statements if no default account');
    my $test_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    $test_client2->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );

    my $old_tick1 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 99,
        underlying => 'R_50',
        quote      => 76.5996,
        bid        => 76.6010,
        ask        => 76.2030,
    });

    my $old_tick2 = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 52,
        underlying => 'R_50',
        quote      => 76.6996,
        bid        => 76.7010,
        ask        => 76.3030,
    });

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });

    my $contract_expired = produce_contract({
        underlying   => $underlying,
        bet_type     => 'FLASHU',
        currency     => 'USD',
        stake        => 100,
        date_start   => $now->epoch - 100,
        date_expiry  => $now->epoch - 50,
        current_tick => $tick,
        entry_tick   => $old_tick1,
        exit_tick    => $old_tick2,
        barrier      => 'S0P',
    });

    my $txn = BOM::Product::Transaction->new({
        client        => $test_client2,
        contract      => $contract_expired,
        price         => 100,
        payout        => $contract_expired->payout,
        amount_type   => 'stake',
        purchase_date => $now->epoch - 101,
    });

    $txn->buy(skip_validation => 1);
    my $result = $c->tcall($method, {client_loginid => $test_client2->loginid});
    is($result->{transactions}[0]{action_type}, 'sell', 'the transaction is sold, so _sell_expired_contracts is called');
    $result = $c->tcall(
        $method,
        {
            client_loginid => $test_client2->loginid,
            args           => {description => 1}});

    is(
        $result->{transactions}[0]{longcode},
        'USD 100.00 payout if Random 50 Index is strictly higher than entry spot at 50 seconds after contract start time.',
        "if have short code, then simple_contract_info is called"
    );
    is($result->{transactions}[2]{longcode}, 'free gift', "if no short code, then longcode is the remark");

    # here the expired contract is sold, so we can get the txns as test value
    my $txns = BOM::Database::DataMapper::Transaction->new({db => $test_client2->default_account->db})
        ->get_transactions_ws({}, $test_client2->default_account);
    $result = $c->tcall($method, {client_loginid => $test_client2->loginid});
    is($result->{transactions}[0]{transaction_time}, Date::Utility->new($txns->[0]{sell_time})->epoch,     'transaction time correct for sell');
    is($result->{transactions}[1]{transaction_time}, Date::Utility->new($txns->[1]{purchase_time})->epoch, 'transaction time correct for buy ');
    is($result->{transactions}[2]{transaction_time}, Date::Utility->new($txns->[2]{payment_time})->epoch,  'transaction time correct for payment');

};

$method = 'balance';
subtest $method => sub {
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => '12345'
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
    );
    ok(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => undef,
                client_loginid => 'CR0021'
            }
            )->{error},
        'no token error if token undef'
    );
    ok(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => $token,
                client_loginid => $test_loginid
            }
            )->{error},
        'no token error if token is valid'
    );

    is($c->tcall($method, {language => 'ZH_CN'})->{error}{message_to_client}, '请登陆。', 'need loginid');
    is(
        $c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                client_loginid => 'CR12345678'
            }
            )->{error}{message_to_client},
        '请登陆。',
        'need a valid client'
    );
    is($c->tcall($method, {client_loginid => $test_loginid})->{balance},  0,  'have 0 balance if no default account');
    is($c->tcall($method, {client_loginid => $test_loginid})->{currency}, '', 'have no currency if no default account');
    my $result = $c->tcall($method, {client_loginid => 'CR0021'});
    is_deeply(
        $result,
        {
            'currency' => 'USD',
            'balance'  => '1505.0000',
            'loginid'  => 'CR0021'
        },
        'result is correct'
    );
};

$method = 'get_account_status';
subtest $method => sub {
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => '12345'
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
    );
    ok(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => undef,
                client_loginid => 'CR0021'
            }
            )->{error},
        'no token error if token undef'
    );
    ok(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => $token,
                client_loginid => $test_loginid
            }
            )->{error},
        'no token error if token is valid'
    );

    is($c->tcall($method, {language => 'ZH_CN'})->{error}{message_to_client}, '请登陆。', 'need loginid');
    is(
        $c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                client_loginid => 'CR12345678'
            }
            )->{error}{message_to_client},
        '请登陆。',
        'need a valid client'
    );
    is_deeply($c->tcall($method, {client_loginid => $test_loginid}), {status => [qw(active)]}, 'no result, active');
    $test_client->set_status('tnc_approval', 'test staff', 1);
    $test_client->save();
    is_deeply(
        $c->tcall($method, {client_loginid => $test_loginid}),
        {status => [qw(active)]},
        'status no tnc_approval, but if no result, it will active'
    );
    $test_client->set_status('ok', 'test staff', 1);
    $test_client->save();
    is_deeply($c->tcall($method, {client_loginid => $test_loginid}), {status => [qw(ok)]}, 'no tnc_approval');

};

$method = 'change_password';
subtest $method => sub {
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => '12345'
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
    );
    isnt(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => undef,
                client_loginid => 'CR0021'
            }
            )->{error},
        '令牌无效。',
        'no token error if token undef'
    );
    isnt(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => $token,
                client_loginid => $test_loginid
            }
            )->{error},
        '令牌无效。',
        'no token error if token is valid'
    );

    is($c->tcall($method, {language => 'ZH_CN'})->{error}{message_to_client}, '请登陆。', 'need loginid');
    is(
        $c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                client_loginid => 'CR12345678'
            }
            )->{error}{message_to_client},
        '请登陆。',
        'need a valid client'
    );
    my $params = {
        language       => 'ZH_CN',
        client_loginid => $test_loginid
    };
    is($c->tcall($method, $params)->{error}{code}, 'PermissionDenied', 'need token_type');
    $params->{token_type} = 'hello';
    is($c->tcall($method, $params)->{error}{code}, 'PermissionDenied', 'need token_type');
    $params->{token_type}         = 'session_token';
    $params->{args}{old_password} = 'old_password';
    $params->{cs_email}           = 'cs@binary.com';
    $params->{client_ip}          = '127.0.0.1';
    is($c->tcall($method, $params)->{error}{message_to_client}, '旧密码不正确。');
    $params->{args}{old_password} = $password;
    $params->{args}{new_password} = $password;

    is($c->tcall($method, $params)->{error}{message_to_client}, '新密码与旧密码相同。');
    $params->{args}{new_password} = '111111111';
    is($c->tcall($method, $params)->{error}{message_to_client}, '密码安全度不够。');
    my $new_password = 'Fsfjxljfwkls3@fs9';
    $params->{args}{new_password} = $new_password;
    clear_mailbox();
    is($c->tcall($method, $params)->{status}, 1, 'update password correctly');
    my $subject = '您的密码已更改。';
    $subject = encode_qp(encode('UTF-8', $subject));
    # I don't know why encode_qp will append two characters "=\n"
    # so I chopped them
    chop($subject);
    chop($subject);
    my %msg = get_email_by_address_subject(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok(%msg, "email received");
    clear_mailbox();
    $user->load;
    isnt($user->password, $hash_pwd, 'user password updated');
    $test_client->load;
    isnt($user->password, $hash_pwd, 'client password updated');
    $password = $new_password;
};

$method = 'cashier_password';
subtest $method => sub {

  is(
     $c->tcall(
               $method,
               {
                language => 'ZH_CN',
                token    => '12345'
               }
              )->{error}{message_to_client},
     '令牌无效。',
     'invalid token error'
    );
  isnt(
       !$c->tcall(
                  $method,
                  {
                   language       => 'ZH_CN',
                   token          => undef,
                   client_loginid => 'CR0021'
                  }
                 )->{error},
       '令牌无效。',
       'no token error if token undef'
      );
  isnt(
       !$c->tcall(
                  $method,
                  {
                   language       => 'ZH_CN',
                   token          => $token,
                   client_loginid => $test_loginid
                  }
                 )->{error},
       '令牌无效。',
       'no token error if token is valid'
      );


    #test lock
    is($c->tcall($method, {})->{error}{code}, 'AuthorizationRequired', 'need loginid');
    is($c->tcall($method, {client_loginid => 'CR12345678'})->{error}{code},             'AuthorizationRequired', 'need a valid client');
    is($c->tcall($method, {client_loginid => $test_client_vr->loginid})->{error}{code}, 'PermissionDenied',      'need real money account');
    my $params = {
        language => 'ZH_CN',
        client_loginid => $test_loginid,
        args           => {}};
    is($c->tcall($method, $params)->{status}, 0, 'no unlock_password && lock_password, and not set password before, status will be 0');
    my $tmp_password     = 'sfjksfSFjsk78Sjlk';
    my $tmp_new_password = 'bjxljkwFWf278xK';
    $test_client->cashier_setting_password($tmp_password);
    $test_client->save;
    is($c->tcall($method, $params)->{status}, 1, 'no unlock_password && lock_password, and set password before, status will be 1');
    $params->{args}{lock_password} = $tmp_new_password;
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Your cashier was locked.', 'return error if already locked');
    $test_client->cashier_setting_password('');
    $test_client->save;
    $params->{args}{lock_password} = $password;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Please use a different password than your login password.',
        'return error if lock password same with user password'
    );
    $params->{args}{lock_password} = '1111111';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Password is not strong enough.', 'check strong');
    $params->{args}{lock_password} = $tmp_new_password;

    clear_mailbox();
    # here I mocked function 'save' to simulate the db failure.
    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock('save', sub { return undef });
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your account.',
        'return error if cannot save password'
    );
    $mocked_client->unmock_all;

    is($c->tcall($method, $params)->{status}, 1, 'set password success');
    my $subject = 'cashier password updated';
    my %msg     = get_email_by_address_subject(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok(%msg, "email received");
    clear_mailbox();

    # test unlock
    $test_client->cashier_setting_password('');
    $test_client->save;
    delete $params->{args}{lock_password};
    $params->{args}{unlock_password} = '123456';
    is($c->tcall($method, $params)->{error}{message_to_client}, 'Your cashier was not locked.', 'return error if not locked');

    clear_mailbox();
    $test_client->cashier_setting_password(BOM::System::Password::hashpw($tmp_password));
    $test_client->save;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, you have entered an incorrect cashier password',
        'return error if not correct'
    );
    $subject = 'Failed attempt to unlock cashier section';
    %msg     = get_email_by_address_subject(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok(%msg, "email received");
    clear_mailbox();

    # here I mocked function 'save' to simulate the db failure.
    $mocked_client->mock('save', sub { return undef });
    $params->{args}{unlock_password} = $tmp_password;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        'Sorry, an error occurred while processing your account.',
        'return error if cannot save'
    );
    $mocked_client->unmock_all;

    clear_mailbox();
    is($c->tcall($method, $params)->{status}, 0, 'unlock password ok');
    $test_client->load;
    ok(!$test_client->cashier_setting_password, 'cashier password unset');
    $subject = 'cashier password updated';
    %msg     = get_email_by_address_subject(
        email   => $email,
        subject => qr/\Q$subject\E/
    );
    ok(%msg, "email received");
    clear_mailbox();
};

done_testing();
