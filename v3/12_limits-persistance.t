use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

my $t = build_wsapi_test();

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;
$client->set_default_account('USD');

my $loginid = $client->loginid;
my $user    = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{msg_type}, 'authorize', "authorised";

my $i = 0;
my $limit_hit = 0;
my $call_type = 'portfolio';
while(!$limit_hit && $i < 500) {
    $t->send_ok({json => {$call_type => 1}})->message_ok;
    my $msg = decode_json($t->message->[1]);
    $limit_hit = ($msg->{error}->{code} // '?') eq 'RateLimit';
    $i++;
}
BAIL_OUT("cannot hit limit after $i attempts, no sense test further")
    if ($i == 500);
pass "rate limit reached";

$t->send_ok({json => {logout => 1}})->message_ok;
my $logout = decode_json($t->message->[1]);
is $logout->{msg_type}, 'logout';
is $logout->{logout}, 1;

$t->send_ok({json => {authorize => $token}})->message_ok;
$authorize = decode_json($t->message->[1]);
is $authorize->{msg_type}, 'authorize', "re-authorised";

$t->send_ok({json => {$call_type => 1}})->message_ok;
my $msg = decode_json($t->message->[1]);
is $msg->{error}->{code}, 'RateLimit', "rate limitations are persisted between invocations";

done_testing;
