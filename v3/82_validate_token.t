use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_mojo_test/;

use BOM::Platform::Client;
use BOM::Platform::User;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

my $t = build_mojo_test();

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

subtest 'validate_oauth_token' => sub {
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    $t = $t->send_ok({json => {authorize => $token}})->message_ok;
    my $res = decode_json($t->message->[1]);
    is $res->{authorize}->{email}, $email, 'Correct email for oauth token';
    test_schema('authorize', $res);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{balance}->{loginid}, $loginid, 'Correct response for balance';
    test_schema('balance', $res);

    # revoke oauth token
    BOM::Database::Model::OAuth->new->revoke_tokens_by_loginid_app($loginid, 1);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code},    'InvalidToken',          'Can not request authenticated (like balance) call when token has expired';
    is $res->{error}->{message}, 'The token is invalid.', 'Correct invalid token message';
    test_schema('balance', $res);

    $t = $t->send_ok({json => {logout => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    ok($res->{logout});
    test_schema('logout', $res);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is($res->{error}->{code}, 'AuthorizationRequired', 'Proper code for authorization rather than invalid token');
};

subtest 'validate_api_token' => sub {
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    $t = $t->send_ok({
            json => {
                api_token => 1,
                new_token => 'Test Token'
            }})->message_ok;
    my $res = decode_json($t->message->[1]);

    ok($res->{api_token});
    ok $res->{api_token}->{new_token};
    is scalar(@{$res->{api_token}->{tokens}}), 1, '1 token created';
    my $test_token = $res->{api_token}->{tokens}->[0];
    is $test_token->{display_name}, 'Test Token';
    test_schema('api_token', $res);

    # authorize with api token
    $t = $t->send_ok({json => {authorize => $test_token->{token}}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{authorize}->{email}, $email, 'Correct email for api token';
    test_schema('authorize', $res);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{balance}->{loginid}, $loginid, 'Correct response for balance';
    test_schema('balance', $res);

    # delete token
    $t = $t->send_ok({
            json => {
                api_token    => 1,
                delete_token => $test_token->{token},
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok($res->{api_token});
    ok $res->{api_token}->{delete_token};
    is_deeply($res->{api_token}->{tokens}, [], 'empty');
    test_schema('api_token', $res);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code},    'InvalidToken',          'Can not request authenticated (like balance) call when token has expired';
    is $res->{error}->{message}, 'The token is invalid.', 'Correct invalid token message';
    test_schema('balance', $res);

    $t = $t->send_ok({json => {logout => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    ok($res->{logout});
    test_schema('logout', $res);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is($res->{error}->{code}, 'AuthorizationRequired', 'Proper code for authorization rather than invalid token');
};

done_testing();
