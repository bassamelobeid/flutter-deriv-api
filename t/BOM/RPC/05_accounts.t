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
my $test_loginid = $test_client->loginid;
my $user            = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;
$user->add_loginid({loginid => $test_loginid});
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

#cleanup
#BOM::Database::Model::AccessToken->new->remove_by_loginid($test_loginid_mf);

#my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
## need to mock it as to access api token we need token beforehand
#$mock_utility->mock('token_to_loginid', sub { return $test_loginid_mf });

## create new api token
#my $res = BOM::RPC::v3::Accounts::api_token({
#        token => 'Abc123',
#        args  => {
#            api_token => 1,
#            new_token => 'Sample1'
#        }});
#is scalar(@{$res->{tokens}}), 1, "token created succesfully for MF client";
#my $token = $res->{tokens}->[0]->{token};
#
#$mock_utility->unmock('token_to_loginid');

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

#$res = BOM::RPC::v3::Accounts::api_token({
#        token => $token,
#        args  => {
#            api_token    => 1,
#            delete_token => $token
#        }});
#is scalar(@{$res->{tokens}}), 0, "MF client token deleted successfully";
#
#$test_loginid = 'CR0021';
# cleanup
#BOM::Database::Model::AccessToken->new->remove_by_loginid($test_loginid);
#
#$mock_utility->mock('token_to_loginid', sub { return $test_loginid });

## create new api token
#$res = BOM::RPC::v3::Accounts::api_token({
#        token => 'Abc123',
#        args  => {
#            api_token => 1,
#            new_token => 'Sample1'
#        }});
#is scalar(@{$res->{tokens}}), 1, "token created succesfully for CR client";
#$token = $res->{tokens}->[0]->{token};
#
#$mock_utility->unmock('token_to_loginid');

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
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => undef,
                client_loginid => 'CR0021'
            }
            )->{error}{message_to_client},
  '令牌无效。',
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
         token => $token,
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
               '令牌无效。',
        'invalid token error'
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

    is($c->tcall($method, {client_loginid => $test_loginid})->{balance},  0,  'have 0 balance if no default account');
    is($c->tcall($method, {client_loginid => $test_loginid})->{currency}, '', 'have no currency if no default account');
    my $result = $c->tcall($method, {token => $token});
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
    is(
        $c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => undef,
            }
            )->{error}{message_to_client},
        '令牌无效。',
        'no token error if token undef'
    );
    ok(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => $token,
            }
            )->{error},
        'no token error if token is valid'
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

#$res = BOM::RPC::v3::Accounts::api_token({
#        token => $token,
#        args  => {
#            api_token    => 1,
#            delete_token => $token
#        }});
#is scalar(@{$res->{tokens}}), 0, "token deleted successfully";

#sub _get_session_token {
#    return BOM::Platform::SessionCookie->new({
#            email      => 'abc@binary.com',
#            loginid    => $test_loginid_mf,
#            expires_in => 3600
#        })->token;
#}

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
                language       => 'ZH_CN',
                token          => undef,
            }
            )->{error},
        '令牌无效。',
        'invlaid token error'
    );
    isnt(
        !$c->tcall(
            $method,
            {
                language       => 'ZH_CN',
                token          => $token,
            }
            )->{error}{message_to_client},
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
        token => $token,
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
    $params->{token} = _get_session_token();
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

done_testing();
