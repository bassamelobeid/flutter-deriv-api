use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::User::Password;
use BOM::User;
use BOM::Test::Helper::Token;
use Test::BOM::RPC::Accounts;
use Test::BOM::RPC::QueueClient;

BOM::Test::Helper::Token::cleanup_redis_tokens();

my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);
my $m        = BOM::Platform::Token::API->new;
my $c        = BOM::Test::RPC::QueueClient->new();
my $tc       = Test::BOM::RPC::QueueClient->new();

my $bal_email = 'balance@binary.com';
my $bal_user  = BOM::User->create(
    email    => $bal_email,
    password => $hash_pwd,
);

my $bal_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
my $bal_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $bal_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});

for my $c ($bal_mf, $bal_cr, $bal_vr) {
    $c->email($bal_email);
    $c->save;
    $bal_user->add_client($c);
}

$bal_mf->set_default_account('EUR');
$bal_mf->save;

$bal_mf->payment_free_gift(
    currency => 'EUR',
    amount   => 1000,
    remark   => 'free gift',
);

$bal_cr->set_default_account('USD');
$bal_cr->save;
$bal_cr->payment_free_gift(
    currency => 'USD',
    amount   => 1005,
    remark   => 'free gift',
);

$bal_vr->set_default_account('USD');
$bal_vr->save;

my $bal_token_cr = $m->create_token($bal_cr->loginid, 'cr token');
my $bal_token_mf = $m->create_token($bal_mf->loginid, 'mf token');
my $bal_token_vr = $m->create_token($bal_vr->loginid, 'vr token');

my $params = {
    token          => $bal_token_cr,
    account_tokens => {
        $bal_cr->loginid => {
            token      => $bal_token_cr,
            broker     => $bal_cr->broker_code,
            is_virtual => $bal_cr->is_virtual
        },
        $bal_mf->loginid => {
            token      => $bal_token_mf,
            broker     => $bal_mf->broker_code,
            is_virtual => $bal_mf->is_virtual
        },
        $bal_vr->loginid => {
            token      => $bal_token_vr,
            broker     => $bal_vr->broker_code,
            is_virtual => $bal_vr->is_virtual
        },
    },
    args => {loginid => $bal_cr->loginid},
};

my $method = 'balance';
subtest 'balance' => sub {

    subtest 'Get CR balance with CR loginid' => sub {
        my $expected_result = {
            'account_id' => $bal_cr->default_account->id,
            'balance'    => '1005.00',
            'currency'   => 'USD',
            'loginid'    => $bal_cr->loginid,
        };

        my $result = $tc->tcall($method, $params);

        is_deeply($result, $expected_result, 'result is correct');
    };

    subtest 'Get MF balance with MF loginid' => sub {

        $params->{args}->{loginid} = $bal_mf->loginid;
        my $expected_result = {
            'account_id' => $bal_mf->default_account->id,
            'balance'    => '1000.00',
            'currency'   => 'EUR',
            'loginid'    => $bal_mf->loginid,
        };

        my $result = $tc->tcall($method, $params);
        is_deeply($result, $expected_result, 'result is correct');
    };

    subtest 'Get VR balance with VR loginid' => sub {

        $params->{args}->{loginid} = $bal_vr->loginid;
        my $expected_result = {
            'account_id' => $bal_vr->default_account->id,
            'balance'    => '0.00',
            'currency'   => 'USD',
            'loginid'    => $bal_vr->loginid,
        };

        my $result = $tc->tcall($method, $params);
        is_deeply($result, $expected_result, 'result is correct');
    };

    subtest 'Call with no loginid argument' => sub {

        delete $params->{args}->{loginid};
        my $expected_result = {
            'account_id' => $bal_cr->default_account->id,
            'balance'    => '1005.00',
            'currency'   => 'USD',
            'loginid'    => $bal_cr->loginid,
        };

        my $result = $tc->tcall($method, $params);
        is_deeply($result, $expected_result, 'result is correct - use default loginid (=authorize token loginid)');
    };

    subtest 'Call with loginid not belonging to user.' => sub {

        $params->{args}->{loginid} = 'MF9876';
        $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'Token is not valid for current user.');
    };

};

done_testing();
