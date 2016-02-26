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


    my $mock_Portfolio          = Test::MockModule->new('BOM::RPC::v3::PortfolioManagement');
    my $_sell_expired_is_called = 0;
    $mock_Portfolio->mock('_sell_expired_contracts',
        sub { $_sell_expired_is_called = 1; });
    my $result = $c->tcall($method, {token => $token_21});
    diag(Dumper($result));
    $mock_Portfolio = undef;
    $result = $c->tcall($method, {token => $token_21});
    diag(Dumper($result));
#    my $mock_Portfolio          = Test::MockModule->new('BOM::RPC::v3::PortfolioManagement');
#    my $_sell_expired_is_called = 0;
#    $mock_Portfolio->mock('_sell_expired_contracts',
#        sub { $_sell_expired_is_called = 1; $mock_Portfolio->original('_sell_expired_contracts')->(@_) });
#    my $mock_fmb = Test::MockModule->new('BOM::Database::DataMapper::FinancialMarketBet');
#    my $get_sold_bets_of_account_args;
#    $mock_fmb->mock(
#        'get_sold_bets_of_account',
#        sub {
#            shift;
#            $get_sold_bets_of_account_args = shift;
#            #clone this args because it is changed in the caller function.
#            $get_sold_bets_of_account_args = {%{$get_sold_bets_of_account_args}};
#            return [{
#                    'sell_time'         => '2005-09-21 09:46:00',
#                    'txn_id'            => '204419',
#                    'expiry_time'       => undef,
#                    'sell_price'        => '237.5',
#                    'id'                => '202319',
#                    'purchase_time'     => '2005-09-21 06:46:00',
#                    'fixed_expiry'      => undef,
#                    'short_code'        => 'RUNBET_DOUBLEDOWN_USD2500_frxUSDJPY_5',
#                    'is_expired'        => 1,
#                    'remark'            => 'frxUSDJPY forecast=DOWN Run=111.518,111.514,111.529,111.523,111.525,111.513,',
#                    'expiry_daily'      => 0,
#                    'start_time'        => undef,
#                    'bet_class'         => 'run_bet',
#                    'is_sold'           => 1,
#                    'payout_price'      => '250',
#                    'account_id'        => '200359',
#                    'bet_type'          => 'RUNBET_DOUBLEDOWN',
#                    'underlying_symbol' => 'frxUSDJPY',
#                    'buy_price'         => '125',
#                    'settlement_time'   => undef,
#                    'tick_count'        => undef
#                },
#
#            ];
#        });
#    my $result = $c->tcall($method, {token => $token_21});
#    is($result->{count}, 1, 'result is correct');
#    is_deeply(
#        $result->{transactions}[0],
#        {
#            'sell_price'     => '237.5',
#            'contract_id'    => '202319',
#            'transaction_id' => '204419',
#            'sell_time'      => '1127295960',
#            'buy_price'      => '125',
#            'purchase_time'  => '1127285160'
#        },
#        'result is correct'
#    );
#    my $mocked_account = Test::MockModule->new('BOM::RPC::v3::Accounts');
#    $mocked_account->mock('simple_contract_info', sub { return ("mocked info") });
#
#    $result = $c->tcall(
#        $method,
#        {
#            token => $token_21,
#            args             => {
#                date_from   => '2015-07-01',
#                date_to     => '2015-08-01',
#                description => 1
#            }});
#
#    is($result->{transactions}[0]{longcode}, "mocked info", "if have short code, then simple_contract_info is called");
#    is_deeply(
#        $get_sold_bets_of_account_args,
#        {
#            after     => '2015-07-01',
#            before    => '2015-08-01',
#            date_from => '2015-07-01',
#            date_to   => '2015-08-01',
#
#            description => 1
#        },
#        'the args feeded to get_sold_bets_of_account is correct'
#    );
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
#
################################################################################

done_testing();
