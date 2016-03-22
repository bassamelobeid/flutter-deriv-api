use strict;
use warnings;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::SessionCookie;
use utf8;
use Data::Dumper;

my $email       = 'dummy@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;
my $user = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $test_client->loginid});
$user->save;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_client->loginid,
    email   => $email
)->token;

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;
my $token_vr = BOM::Platform::SessionCookie->new(
    loginid => $test_client_vr->loginid,
    email   => $email
)->token;

is $test_client->default_account, undef, 'new client has no default account';

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'authorize';
subtest $method => sub {
    my $params = {
        language => 'zh_CN',
        token    => 12345
    };

    $c->call_ok($method, $params)->has_error->error_message_is('令牌无效。', 'check invalid token');
    $params->{token} = $token;
    my $expected_result = {
        fullname             => $test_client->full_name,
        loginid              => $test_client->loginid,
        balance              => 0,
        currency             => '',
        email                => 'dummy@binary.com',
        account_id           => '',
        landing_company_name => 'costarica',
        country              => 'id',
        scopes               => [qw(read trade admin payments)],
        is_virtual           => 0,
    };
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is correct');

    $test_client->set_default_account('USD');
    $test_client->save;
    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    $expected_result->{account_id} = $test_client->default_account->id;
    $expected_result->{currency}   = 'USD';
    $expected_result->{balance}    = '1000.0000';
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is correct');

    $params->{token} = $token_vr;
    is($c->call_ok($method, $params)->has_no_error->result->{is_virtual}, 1, "is_virtual is true if client is virtual");
};

subtest 'logout' => sub {

    my $new_token = BOM::Platform::SessionCookie->new(
        loginid => $test_client->loginid,
        email   => $email
    )->token;

    my $params = {
        client_email => $email,
        client_ip    => '1.1.1.1',
        country_code => 'id',
        language     => 'ZH_CN',
        ua           => 'firefox',
        token_type   => 'session_token',
        token        => $new_token
    };
    $c->call_ok('logout', $params)->has_no_error->result_is_deeply({status => 1});

    #check login history
    my $history_records = $c->call_ok(
        'login_history',
        {
            token => $token,
            args  => {limit => 1}})->has_no_error->result->{records};
    is($history_records->[0]{action}, 'logout', 'the last history is logout');
    like($history_records->[0]{environment}, qr/IP=1.1.1.1 IP_COUNTRY=ID User_AGENT= LANG=ZH_CN/, 'environment is correct');

    $c->call_ok(
        'authorize',
        {
            language => 'ZH_CN',
            token    => $new_token
        })->has_error->error_message_is('令牌无效。', 'session token is invalid after logout');

};

subtest 'self_exclusion' => sub {
    my $params = {
        language => 'en',
        token    => $token
    };
    # This is how long I think binary.com can survive using Perl in its concurrency paradigm era.
    # If this test ever failed because of setting this date too short, we might be in bigger troubles than a failing test.
    $test_client->set_exclusion->exclude_until('2020-01-01');
    $test_client->save();

    $c->call_ok($method, $params)
        ->has_error->error_message_is('Sorry, you have excluded yourself until 2020-01-01T00:00:00.', 'check if authorize check self exclusion');
};

done_testing();
