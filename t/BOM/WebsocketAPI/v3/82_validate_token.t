use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::SessionCookie;
use BOM::Database::Model::OAuth;

my $t = build_mojo_test();
my ($session, $token, $res);

subtest 'validate_session_token' => sub {
    $session = BOM::Platform::SessionCookie->new(
        loginid => "CR0021",
        email   => 'shuwnyuan@regentmarkets.com',
    );

    $token = $session->token;

    $t = $t->send_ok({json => {authorize => $token}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{authorize}->{email}, 'shuwnyuan@regentmarkets.com', 'Correct email for session cookie token';
    test_schema('authorize', $res);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{balance}->{loginid}, 'CR0021', 'Correct response for balance';
    test_schema('balance', $res);

    # end session to invalidate the token
    $session->end_session;

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{error}->{code},    'InvalidToken',          'Can not request authenticated (like balance) call when token has expired';
    is $res->{error}->{message}, 'The token is invalid.', 'Correct invalid token message';
    test_schema('balance', $res);

    $t = $t->send_ok({json => {logout => 1}})->message_ok;
    my $res = decode_json($t->message->[1]);
    ok($res->{logout});
    test_schema('logout', $res);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is($res->{error}->{code}, 'AuthorizationRequired', 'Proper code for authorization rather than invalid token');
};

subtest 'validate_api_token' => sub {
    $session = BOM::Platform::SessionCookie->new(
        loginid => "CR0021",
        email   => 'shuwnyuan@regentmarkets.com',
    );
    $token = $session->token;

    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    $t = $t->send_ok({
            json => {
                api_token => 1,
                new_token => 'Test Token'
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok($res->{api_token});
    ok $res->{api_token}->{new_token};
    is scalar(@{$res->{api_token}->{tokens}}), 1, '1 token created';
    my $test_token = $res->{api_token}->{tokens}->[0];
    is $test_token->{display_name}, 'Test Token';
    test_schema('api_token', $res);

    $session->end_session;

    # authorize with api token
    $t = $t->send_ok({json => {authorize => $test_token->{token}}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{authorize}->{email}, 'shuwnyuan@regentmarkets.com', 'Correct email for api token';
    test_schema('authorize', $res);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{balance}->{loginid}, 'CR0021', 'Correct response for balance';
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
    my $res = decode_json($t->message->[1]);
    ok($res->{logout});
    test_schema('logout', $res);

    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = decode_json($t->message->[1]);
    is($res->{error}->{code}, 'AuthorizationRequired', 'Proper code for authorization rather than invalid token');
};

done_testing();
