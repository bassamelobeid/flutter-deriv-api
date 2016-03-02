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
    my $r      = $self->call_response($method, $params);
    ok($r->result,    'rpc response ok');
    ok(!$r->is_error, 'rpc response ok');
    if ($r->is_error) {
        diag(Dumper($r));
    }
    return $r->result;
}

sub call_response {
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
    return $r;
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

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $test_client2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

$test_client_disabled->set_status('disabled', 1, 'test disabled');
$test_client_disabled->save();

my $m              = BOM::Database::Model::AccessToken->new;
my $token1         = $m->create_token($test_loginid, 'test token');
my $token_21       = $m->create_token('CR0021', 'test token');
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_vr       = $m->create_token($test_client_vr->loginid, 'test token');
my $token_with_txn = $m->create_token($test_client2->loginid, 'test token');

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

################################################################################
# test begin
################################################################################

my $t = Test::Mojo->new('BOM::RPC');
my $c = MojoX::JSON::RPC::Client->new(ua => $t->app->ua);

################################################################################
# payout_currencies
################################################################################
my $method = 'payout_currencies';
subtest $method => sub {
    is_deeply(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => '12345'
            }
        ),
        [qw(USD EUR GBP AUD)],
        'invalid token will get all currencies'
    );
    is_deeply(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => undef,
            }
        ),
        [qw(USD EUR GBP AUD)],
        'undefined token will get all currencies'
    );

    is_deeply($c->tcall($method, {token => $token_21}), ['USD'], "will return client's currency");
    is_deeply($c->tcall($method, {}), [qw(USD EUR GBP AUD)], "will return legal currencies if no token");
};

################################################################################
# landing_company
################################################################################
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

################################################################################
# landing_company_details
################################################################################
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

################################################################################
# statement
################################################################################
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
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => undef,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error if token undef'
    );
    isnt(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token1,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'no token error if token is valid'
    );

    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_disabled,
            }
            )->{error}{message_to_client},
        '此账户不可用。',
        'check authorization'
    );
    is($c->tcall($method, {token => $token_21})->{count}, 100, 'have 100 statements');
    is($c->tcall($method, {token => $token1})->{count},   0,   'have 0 statements if no default account');

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

    my $result = $c->tcall($method, {token => $token_with_txn});
    is($result->{transactions}[0]{action_type}, 'sell', 'the transaction is sold, so _sell_expired_contracts is called');
    $result = $c->tcall(
        $method,
        {
            token => $token_with_txn,
            args  => {description => 1}});

    is(
        $result->{transactions}[0]{longcode},
        'USD 100.00 payout if Random 50 Index is strictly higher than entry spot at 50 seconds after contract start time.',
        "if have short code, then simple_contract_info is called"
    );
    is($result->{transactions}[2]{longcode}, 'free gift', "if no short code, then longcode is the remark");

    # here the expired contract is sold, so we can get the txns as test value
    my $txns = BOM::Database::DataMapper::Transaction->new({db => $test_client2->default_account->db})
        ->get_transactions_ws({}, $test_client2->default_account);
    $result = $c->tcall($method, {token => $token_with_txn});
    is($result->{transactions}[0]{transaction_time}, Date::Utility->new($txns->[0]{sell_time})->epoch,     'transaction time correct for sell');
    is($result->{transactions}[1]{transaction_time}, Date::Utility->new($txns->[1]{purchase_time})->epoch, 'transaction time correct for buy ');
    is($result->{transactions}[2]{transaction_time}, Date::Utility->new($txns->[2]{payment_time})->epoch,  'transaction time correct for payment');

};
################################################################################
# profit_table
################################################################################

$method = 'profit_table';
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
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => undef,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error if token undef'
    );
    isnt(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token1,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'no token error if token is valid'
    );

    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_disabled,
            }
            )->{error}{message_to_client},
        '此账户不可用。',
        'check authorization'
    );

    #create a new transaction for test
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

    my $result = $c->tcall($method, {token => $token_with_txn});
    is($result->{count}, 2, 'the new transaction is sold so _sell_expired_contracts is called');

    my $fmb_dm = BOM::Database::DataMapper::FinancialMarketBet->new({
            client_loginid => $test_client2->loginid,
            currency_code  => $test_client2->currency,
            db             => BOM::Database::ClientDB->new({
                    client_loginid => $test_client2->loginid,
                    operation      => 'replica',
                }
            )->db,
        });
    my $args    = {};
    my $data    = $fmb_dm->get_sold_bets_of_account($args);
    my $expect0 = {
        'sell_price'     => '100',
        'contract_id'    => $txn->contract_id,
        'transaction_id' => $txn->transaction_id,
        'sell_time'      => Date::Utility->new($data->[0]{sell_time})->epoch,
        'buy_price'      => '100',
        'purchase_time'  => Date::Utility->new($data->[0]{purchase_time})->epoch,
    };

    is_deeply($result->{transactions}[0], $expect0, 'result is correct');
    $expect0->{longcode}  = 'USD 100.00 payout if Random 50 Index is strictly higher than entry spot at 50 seconds after contract start time.';
    $expect0->{shortcode} = $data->[0]{short_code};
    $result               = $c->tcall(
        $method,
        {
            token => $token_with_txn,
            args  => {description => 1}});
    is_deeply($result->{transactions}[0], $expect0, 'the result with description ok');
    is(
        $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {after => '2006-01-01 01:01:01'}}
            )->{count},
        0,
        'result is correct for arg after'
    );
    is(
        $c->tcall(
            $method,
            {
                token => $token_with_txn,
                args  => {before => '2004-01-01 01:01:01'}}
            )->{count},
        0,
        'result is correct for arg after'
    );
};

################################################################################
# balance
################################################################################
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
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => undef,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
    );
    isnt(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token1,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'no token error if token is valid'
    );

    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_disabled,
            }
            )->{error}{message_to_client},
        '此账户不可用。',
        'check authorization'
    );

    is($c->tcall($method, {token => $token1})->{balance},  0,  'have 0 balance if no default account');
    is($c->tcall($method, {token => $token1})->{currency}, '', 'have no currency if no default account');
    my $result = $c->tcall($method, {token => $token_21});
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

################################################################################
# get_account_status
################################################################################
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
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => undef,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
    );
    isnt(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token1,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'no token error if token is valid'
    );
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_disabled,
            }
            )->{error}{message_to_client},
        '此账户不可用。',
        'check authorization'
    );

    is_deeply($c->tcall($method, {token => $token1}), {status => [qw(active)]}, 'no result, active');
    $test_client->set_status('tnc_approval', 'test staff', 1);
    $test_client->save();
    is_deeply($c->tcall($method, {token => $token1}), {status => [qw(active)]}, 'status no tnc_approval, but if no result, it will active');
    $test_client->set_status('ok', 'test staff', 1);
    $test_client->save();
    is_deeply($c->tcall($method, {token => $token1}), {status => [qw(ok)]}, 'no tnc_approval');

};

################################################################################
# change_password
################################################################################
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
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => undef,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invlaid token error'
    );
    isnt(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token1,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'no token error if token is valid'
    );
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_disabled,
            }
            )->{error}{message_to_client},
        '此账户不可用。',
        'check authorization'
    );

    is($c->tcall($method, {language => 'ZH_CN'})->{error}{message_to_client}, '令牌无效。', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_disabled,
            }
            )->{error}{message_to_client},
        '此账户不可用。',
        'need a valid client'
    );
    my $params = {
        language => 'ZH_CN',
        token    => $token1,
    };
    is($c->tcall($method, $params)->{error}{message_to_client}, '权限不足。', 'need token_type');
    $params->{token_type} = 'hello';
    is($c->tcall($method, $params)->{error}{message_to_client}, '权限不足。', 'need token_type');
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

################################################################################
# cashier_password
################################################################################
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

    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => undef,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
    );
    isnt(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token1,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'no token error if token is valid'
    );

    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_disabled,
            }
            )->{error}{message_to_client},
        '此账户不可用。',
        'check authorization'
    );
    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_vr
            }
            )->{error}{message_to_client},
        '权限不足。',
        'need real money account'
    );
    my $params = {
        language => 'ZH_CN',
        token    => $token1,
        args     => {}};
    is($c->tcall($method, $params)->{status}, 0, 'no unlock_password && lock_password, and not set password before, status will be 0');
    my $tmp_password     = 'sfjksfSFjsk78Sjlk';
    my $tmp_new_password = 'bjxljkwFWf278xK';
    $test_client->cashier_setting_password($tmp_password);
    $test_client->save;
    is($c->tcall($method, $params)->{status}, 1, 'no unlock_password && lock_password, and set password before, status will be 1');
    $params->{args}{lock_password} = $tmp_new_password;
    is($c->tcall($method, $params)->{error}{message_to_client}, '您的收银台已被锁定。', 'return error if already locked');
    $test_client->cashier_setting_password('');
    $test_client->save;
    $params->{args}{lock_password} = $password;
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        '请使用与登录密码不同的密码。',
        'return error if lock password same with user password'
    );
    $params->{args}{lock_password} = '1111111';
    is($c->tcall($method, $params)->{error}{message_to_client}, '密码安全度不够。', 'check strong');
    $params->{args}{lock_password} = $tmp_new_password;

    clear_mailbox();
    # here I mocked function 'save' to simulate the db failure.
    my $mocked_client = Test::MockModule->new(ref($test_client));
    $mocked_client->mock('save', sub { return undef });
    is(
        $c->tcall($method, $params)->{error}{message_to_client},
        '对不起，在处理您的账户时出错。',
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
    is($c->tcall($method, $params)->{error}{message_to_client}, '您的收银台没有被锁定。', 'return error if not locked');

    clear_mailbox();
    $test_client->cashier_setting_password(BOM::System::Password::hashpw($tmp_password));
    $test_client->save;
    is($c->tcall($method, $params)->{error}{message_to_client}, '对不起，您输入的收银台密码不正确', 'return error if not correct');
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
    is($c->tcall($method, $params)->{error}{message_to_client}, '对不起，在处理您的账户时出错。', 'return error if cannot save');
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

################################################################################
# get_settings
################################################################################
$method = 'get_settings';
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

    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => undef,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
    );
    isnt(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token1,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'no token error if token is valid'
    );

    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_disabled,
            }
            )->{error}{message_to_client},
        '此账户不可用。',
        'check authorization'
    );

    my $params = {
        token    => $token_21,
        language => 'ZH_CN'
    };
    my $result = $c->tcall($method, $params);
    is_deeply(
        $result,
        {
            'country'                        => '澳大利亚',
            'salutation'                     => 'Ms',
            'is_authenticated_payment_agent' => '0',
            'country_code'                   => 'au',
            'date_of_birth'                  => '315532800',
            'address_state'                  => '',
            'address_postcode'               => '85010',
            'phone'                          => '069782001',
            'last_name'                      => 'tee',
            'email'                          => 'shuwnyuan@regentmarkets.com',
            'address_line_2'                 => 'Jln Address 2 Jln Address 3 Jln Address 4',
            'address_city'                   => 'Segamat',
            'address_line_1'                 => '53, Jln Address 1',
            'first_name'                     => 'shuwnyuan'
        });

    $params->{token} = $token1;
    $test_client->set_status('tnc_approval', 'system', 1);
    $test_client->save;
    is($c->tcall($method, $params)->{client_tnc_status}, 1, 'tnc status set');
    $params->{token} = $token_vr;
    is_deeply(
        $c->tcall($method, $params),
        {
            'email'        => 'abc@binary.com',
            'country'      => '印度尼西亚',
            'country_code' => 'id',
        },
        'vr client return less messages'
    );
};

################################################################################
# set_settings
################################################################################
$method = 'set_settings';
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

    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => undef,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
    );

    is(
        $c->tcall(
            $method,
            {
                language => 'ZH_CN',
                token    => $token_disabled,
            }
            )->{error}{message_to_client},
        '此账户不可用。',
        'check authorization'
    );
    my $mocked_client = Test::MockModule->new(ref($test_client));
    my $params        = {
        language => 'ZH_CN',
        token    => $token_vr,
        args     => {address1 => 'Address 1'}};
    # in normal case the vr client's residence should not be null, so I update is as '' to simulate null
    $test_client_vr->residence('');
    $test_client_vr->save();
    is($c->tcall($method, $params)->{error}{message_to_client}, '权限不足。', "vr client can only update residence");
    # here I mocked function 'save' to simulate the db failure.
    $mocked_client->mock('save', sub { return undef });
    $params->{args}{residence} = 'zh';
    is($c->tcall($method, $params)->{error}{message_to_client}, '对不起，在处理您的账户时出错。', 'return error if cannot save');
    $mocked_client->unmock('save');
    my $result = $c->tcall($method, $params);
    is($result->{status}, 1, 'vr account update residence successfully');
    $test_client_vr->load;
    isnt($test_client->address_1, 'Address 1', 'But vr account only update residence');

    # test real account
    $params->{token} = $token1;
    is($c->tcall($method, $params)->{error}{message_to_client}, '权限不足。', 'real account cannot update residence');
    my %full_args = (
        address_line_1   => 'address line 1',
        address_line_2   => 'address line 2',
        address_city     => 'address city',
        address_state    => 'address state',
        address_postcode => '12345',
        phone            => '2345678',
    );
    $params->{args} = {%full_args};
    delete $params->{args}{address_line_1};
    ok($c->call_response($method, $params)->is_error, 'has error because address line 1 cannot be null');
    $params->{args} = {%full_args};
    $mocked_client->mock('save', sub { return undef });
    is($c->tcall($method, $params)->{error}{message_to_client}, '对不起，在处理您的账户时出错。', 'return error if cannot save');
    $mocked_client->unmock_all;
    # add_note should send an email to support address,
    # but it is disabled when the test is running on travis-ci
    # so I mocked this function to check it is called.
    my $add_note_called;
    $mocked_client->mock('add_note', sub { $add_note_called = 1 });
    my $old_latest_environment = $test_client->latest_environment;
    clear_mailbox();
    is($c->tcall($method, $params)->{status}, 1, 'update successfully');
    ok($add_note_called, 'add_note is called, so the email should be sent to support address');
    $test_client->load();
    isnt($test_client->latest_environment, $old_latest_environment, "latest environment updated");
    like($test_client->latest_environment, qr/LANG=ZH_CN/, 'latest environment updated');
    my $subject = '账户设置更改';
    $subject = encode_qp(encode('UTF-8', $subject));
    # I don't know why encode_qp will append two characters "=\n"
    # so I chopped them
    chop($subject);
    chop($subject);
    my %msg = get_email_by_address_subject(
        email   => $test_client->email,
        subject => qr/\Q$subject\E/
    );
    ok(%msg, 'send a email to client');
    like($msg{body}, qr/>address line 1, address line 2, address city, address state, 12345, Indonesia/s, 'email content correct');
    clear_mailbox();
};

################################################################################
# _get_self_exclusion_details
################################################################################

################################################################################
# set_self_exclusion 
################################################################################
$method = 'set_self_exclusion';
subtest 'get and set self_exclusion' => sub{
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

     is(
        $c->tcall(
                  $method,
                  {
                   language => 'ZH_CN',
                   token    => undef,
                  }
                 )->{error}{message_to_client},
        '令牌无效。',
        'invalid token error'
       );

     is(
        $c->tcall(
                  $method,
                  {
                   language => 'ZH_CN',
                   token    => $token_disabled,
                  }
                 )->{error}{message_to_client},
        '此账户不可用。',
        'check authorization'
       );
   
     my $params = {language => 'ZH_CN', token => $token_vr, args => {}};
     is($c->tcall($method, $params)->{error}{message_to_client}, "权限不足。", 'vr client cannot set exclusion');
     $params->{token} = $token1;
     is($c->tcall($method, $params)->{error}{message_to_client}, "请提供至少一个自我禁止设置。", "need one exclusion");
     $params->{args} = {
                                    set_self_exclusion => 1,
                        max_balance        => 10000,
                        max_open_bets      => 100,
                        max_turnover       => undef, # null should be OK to pass
                        max_7day_losses    => 0, # 0 is ok to pass but not saved
                       };
     clear_mailbox();
     is($c->tcall($method, $params)->{status},1, "update self_exclusion ok");
     delete $params->{args};
     is_deeply($c->tcall('get_self_exclusion', $params), {'max_open_bets' => '100', 'max_balance' => '10000'},'get self_exclusion ok');
     my %msg = get_email_by_address_subject(email => 'qa-alerts@regentmarkets.com,support@binary.com', subject => qr/Client set self-exclusion limits/);
     ok(%msg, "msg sent to support email");
     like($msg{body}, qr/Maximum number of open positions: 100.*Maximum account balance: 10000/s, 'email content is ok');
     $params->{args} = {            set_self_exclusion => 1,
                                    max_balance        => 10001,
                                    max_turnover       => 1000,
                                    max_open_bets      => 100,
                       };
     is_deeply($c->tcall($method, $params)->{error},{  'message_to_client' => "请输入0和10000之间的数字。",
               'details' => 'max_balance',
               'code' => 'SetSelfExclusionError'});
     $params->{args} = {
                        set_self_exclusion     => 1,
                        max_balance            => 9999,
                        max_turnover           => 1000,
                        max_open_bets          => 100,
                        session_duration_limit => 1440 * 42 + 1,
                       };
      is_deeply($c->tcall($method, $params)->{error},{  'message_to_client' => "交易期持续时间限制不能大于 6周。",
                                                        'details' => 'session_duration_limit',
                                                        'code' => 'SetSelfExclusionError'});
     $params->{args} = {
                        set_self_exclusion     => 1,
                        max_balance            => 9999,
                        max_turnover           => 1000,
                        max_open_bets          => 100,
                        session_duration_limit => 1440,
                                   exclude_until          => '2010-01-01'
                       };
       is_deeply($c->tcall($method, $params)->{error},{  'message_to_client' => "交易期持续时间限制不能大于 6周。",
                                                         'details' => 'exclude_until',
                                                         'code' => 'SetSelfExclusionError'});
 



};

done_testing();
