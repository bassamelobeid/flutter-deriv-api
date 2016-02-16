use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = build_mojo_test();

my $token = BOM::Platform::SessionCookie->new(
    loginid => "CR0021",
    email   => 'shuwnyuan@regentmarkets.com',
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;

$t = $t->send_ok({json => {api_token => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
ok($res->{api_token});
is_deeply($res->{api_token}->{tokens}, [], 'empty');
test_schema('api_token', $res);

# create new token
$t = $t->send_ok({
        json => {
            api_token        => 1,
            new_token        => 'Test Token',
            new_token_scopes => ['read']}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{api_token});
ok $res->{api_token}->{new_token};
is scalar(@{$res->{api_token}->{tokens}}), 1, '1 token created';
my $test_token = $res->{api_token}->{tokens}->[0];
is $test_token->{display_name}, 'Test Token';
test_schema('api_token', $res);

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

## re-create
$t = $t->send_ok({
        json => {
            api_token => 1,
            new_token => '1'
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error}->{message} =~ /alphanumeric with space and dash/, 'alphanumeric with space and dash';
test_schema('api_token', $res);

$t = $t->send_ok({
        json => {
            api_token => 1,
            new_token => '1' x 33
        }})->message_ok;
$res = decode_json($t->message->[1]);
ok $res->{error}->{message} =~ /alphanumeric with space and dash/, 'alphanumeric with space and dash';
test_schema('api_token', $res);

# $t = $t->send_ok({
#         json => {
#             api_token => 1,
#             new_token => 'Test'
#         }})->message_ok;
# $res = decode_json($t->message->[1]);
# ok $res->{error}->{message} =~ /new_token_scopes/, 'new_token_scopes is required';
# test_schema('api_token', $res);

$t = $t->send_ok({
        json => {
            api_token        => 1,
            new_token        => 'Test',
            new_token_scopes => ['read']}})->message_ok;
$res = decode_json($t->message->[1]);
is scalar(@{$res->{api_token}->{tokens}}), 1, '1 token created';
$test_token = $res->{api_token}->{tokens}->[0];
is $test_token->{display_name}, 'Test';
ok !$test_token->{last_used}, 'last_used is null';
test_schema('api_token', $res);

$t->finish_ok;

# try with the new token
$t   = build_mojo_test();
$t   = $t->send_ok({json => {authorize => $test_token->{token}}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{authorize}->{email}, 'shuwnyuan@regentmarkets.com';

$t = $t->send_ok({json => {api_token => 1}})->message_ok;
$res = decode_json($t->message->[1]);
ok($res->{api_token});
is scalar(@{$res->{api_token}->{tokens}}), 1, '1 token';
$test_token = $res->{api_token}->{tokens}->[0];
is $test_token->{display_name}, 'Test';
ok $test_token->{last_used},    'last_used is ok';
test_schema('api_token', $res);

$t = $t->send_ok({
        json => {
            api_token    => 1,
            delete_token => $test_token->{token},
        }})->message_ok;

$t->finish_ok;

done_testing();
