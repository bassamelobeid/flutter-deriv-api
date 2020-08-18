use strict;
use warnings;
use Test::More;
use Encode;
use JSON::MaybeXS;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

my $t    = build_wsapi_test();
my $json = JSON::MaybeXS->new;

# check for authenticated call
$t = $t->send_ok({json => {reality_check => 1}})->message_ok;
my $response = $json->decode(Encode::decode_utf8($t->message->[1]));

is $response->{error}->{code},    'AuthorizationRequired';
is $response->{error}->{message}, 'Please log in.';

my $email       = 'test-binary' . rand(999) . '@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$test_client->email($email);
$test_client->save;

my $loginid = $test_client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($test_client);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{authorize}->{loginid}, $loginid;

$t   = $t->send_ok({json => {reality_check => 1}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
test_schema('reality_check', $res);

done_testing();

