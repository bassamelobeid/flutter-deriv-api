use strict;
use warnings;
use utf8;
use Test::More;
use Test::Deep;
use Test::Mojo;
use Test::BOM::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::API;
use BOM::Test::Helper::Token;

BOM::Test::Helper::Token::cleanup_redis_tokens();

my $test_client_disabled = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$test_client_disabled->status->set('disabled', 1, 'test disabled');

my $test_client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client_cr->email('sample@binary.com');
$test_client_cr->save;

my $m              = BOM::Platform::Token::API->new;
my $token_disabled = $m->create_token($test_client_disabled->loginid, 'test token');
my $token_with_txn = $m->create_token($test_client_mf->loginid, 'test token');
my $token_cr       = $m->create_token($test_client_cr->loginid, 'test token');

$test_client_mf->payment_free_gift(
    currency => 'USD',
    amount   => 1000,
    remark   => 'free gift',
);

my $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
my $c = Test::BOM::RPC::Client->new(ua => $t->app->ua);

my $method = 'account_statistics';
subtest 'account statistics' => sub {

    is($c->tcall($method, {token => '12345'})->{error}{message_to_client}, 'The token is invalid.', 'invalid token error');
    is(
        $c->tcall(
            $method,
            {
                token => undef,
            }
            )->{error}{message_to_client},
        'The token is invalid.',
        'invalid token error if token undef'
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

    my $res = $c->tcall($method, {token => $token_with_txn});
    ok($res->{total_deposits} eq '1000.00', 'test_client2 has deposit of 1000.00');
    ok($res->{total_withdrawals} eq '0.00', 'test_client2 has withdrawals of 0.00');
    ok($res->{currency} eq 'USD',           'currency is USD');

    $test_client_mf->payment_free_gift(
        currency => 'USD',
        amount   => -200,
        remark   => 'not so free gift',
    );

    $test_client_mf->payment_free_gift(
        currency => 'USD',
        amount   => 2000,
        remark   => 'free gift',
    );

    $res = $c->tcall($method, {token => $token_with_txn});
    ok($res->{total_deposits} eq '3000.00',   'total_deposits is 3000.00');
    ok($res->{total_withdrawals} eq '200.00', 'total_withdrawals is 200.00');
    ok($res->{currency} eq 'USD',             'currency is USD');

    $test_client_mf->payment_free_gift(
        currency => 'USD',
        amount   => -1800,
        remark   => 'not so free gift',
    );

    $res = $c->tcall($method, {token => $token_with_txn});
    ok($res->{total_deposits} eq '3000.00',    'total_deposits is 3000.00');
    ok($res->{total_withdrawals} eq '2000.00', 'total_withdrawals is 2000.00');
    ok($res->{currency} eq 'USD',              'currency is USD');

    # token_cr_2 client does not have a default account, so the currency contain nothing
    $res = $c->tcall($method, {token => $token_cr});
    ok($res->{total_deposits} eq '0.00',    'total_deposits is 0.00');
    ok($res->{total_withdrawals} eq '0.00', 'total_withdrawals is 0.00');
    ok($res->{currency} eq '',              'currency is undef');

};

done_testing();
