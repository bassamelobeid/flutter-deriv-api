use strict;
use warnings;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Database::Model::OAuth;
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

my $oauth = BOM::Database::Model::OAuth->new;
my ($token) = $oauth->store_access_token_only(1, $test_client->loginid);

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client_vr->email($email);
$test_client_vr->save;

my ($token_vr) = $oauth->store_access_token_only(1, $test_client_vr->loginid);

is $test_client->default_account, undef, 'new client has no default account';

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'authorize';
subtest $method => sub {
    my $params = {
        language => 'EN',
        token    => 12345
    };

    $c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');
    $params->{token} = $token;
    my $expected_result = {
        'stash' => {
            'email'                => 'dummy@binary.com',
            'scopes'               => ['read', 'admin', 'trade', 'payments'],
            'country'              => 'id',
            'loginid'              => $test_client->loginid,
            'token'                => $token,
            'token_type'           => 'oauth_token',
            'account_id'           => '',
            'currency'             => '',
            'landing_company_name' => 'costarica',
            'is_virtual'           => '0'
        },
        'currency'             => '',
        'email'                => 'dummy@binary.com',
        'scopes'               => ['read', 'admin', 'trade', 'payments'],
        'balance'              => '0.00',
        'landing_company_name' => 'costarica',
        'fullname'             => $test_client->full_name,
        'loginid'              => $test_client->loginid,
        'is_virtual'           => '0'
    };
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is correct');

    $test_client->set_default_account('USD');
    $test_client->save;
    $test_client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
    );
    $expected_result->{stash}->{account_id} = $test_client->default_account->id;
    $expected_result->{currency} = $expected_result->{stash}->{currency} = 'USD';
    $expected_result->{balance} = '1000.00';
    $c->call_ok($method, $params)->has_no_error->result_is_deeply($expected_result, 'result is correct');

    $params->{token} = $token_vr;
    is($c->call_ok($method, $params)->has_no_error->result->{is_virtual}, 1, "is_virtual is true if client is virtual");
};

my $new_token;
subtest 'logout' => sub {
    ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

    my $params = {
        email        => $email,
        client_ip    => '1.1.1.1',
        country_code => 'id',
        language     => 'EN',
        ua           => 'firefox',
        token_type   => 'oauth_token',
        token        => $token
    };
    $c->call_ok('logout', $params)->has_no_error->result_is_deeply({status => 1});

    #check login history
    ($new_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);
    my $history_records = $c->call_ok(
        'login_history',
        {
            token => $new_token,
            args  => {limit => 1}})->has_no_error->result->{records};
    is($history_records->[0]{action}, 'logout', 'the last history is logout');
    like($history_records->[0]{environment}, qr/IP=1.1.1.1 IP_COUNTRY=ID User_AGENT= LANG=EN/, 'environment is correct');

    $c->call_ok(
        'authorize',
        {
            language => 'EN',
            token    => $token
        })->has_error->error_message_is('The token is invalid.', 'oauth token is invalid after logout');

};

$token = $new_token;

subtest 'self_exclusion timeout' => sub {
    my $params = {
        language => 'en',
        token    => $token
    };
    my $timeout_until = Date::Utility->new->plus_time_interval('1d');
    $test_client->set_exclusion->timeout_until($timeout_until->epoch);
    $test_client->save();

    $c->call_ok($method, $params)
        ->has_error->error_message_is('Sorry, you have excluded yourself until ' . $timeout_until->datetime_yyyymmdd_hhmmss_TZ . '.',
        'check if authorize check self exclusion');
};

subtest 'self_exclusion' => sub {
    my $params = {
        language => 'en',
        token    => $token
    };
    # This is how long I think binary.com can survive using Perl in its concurrency paradigm era.
    # If this test ever failed because of setting this date too short, we might be in bigger troubles than a failing test.
    $test_client->set_exclusion->timeout_until(0);
    $test_client->set_exclusion->exclude_until('2020-01-01');
    $test_client->save();

    $c->call_ok($method, $params)
        ->has_error->error_message_is('Sorry, you have excluded yourself until 2020-01-01.', 'check if authorize check self exclusion');
};

done_testing();
