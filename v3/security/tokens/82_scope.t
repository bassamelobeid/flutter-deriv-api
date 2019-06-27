use strict;
use warnings;
use Test::More;
use Encode;
use JSON::MaybeXS;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test create_test_user/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Database::Model::OAuth;

my $t    = build_wsapi_test();
my $cr_1 = create_test_user();
my $json = JSON::MaybeXS->new;
# cleanup
my $oauth = BOM::Database::Model::OAuth->new();
my $dbh   = $oauth->dbic->dbh;
$dbh->do("DELETE FROM oauth.access_token");
$dbh->do("DELETE FROM oauth.user_scope_confirm");
$dbh->do("DELETE FROM oauth.official_apps");
$dbh->do("DELETE FROM oauth.apps WHERE id <> 1");

## create test app for scopes
my $app = $oauth->create_app({
    name    => 'Test App',
    scopes  => ['read'],
    user_id => 999
});
my $app_id = $app->{app_id};

my ($token) = $oauth->store_access_token_only($app_id, $cr_1);
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = $json->decode(Encode::decode_utf8($t->message->[1]));
is $authorize->{authorize}->{loginid}, $cr_1;
$t = $t->send_ok({json => {sell_expired => 1}})->message_ok;
my $res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{error}->{code}, 'PermissionDenied', 'PermissionDenied b/c it is trade';
$t = $t->send_ok({json => {get_account_status => 1}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
ok $res->{get_account_status}, 'get_account_status is read scope';

($token) = BOM::Database::Model::OAuth->new->store_access_token_only($app_id, $cr_1);
$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$authorize = $json->decode(Encode::decode_utf8($t->message->[1]));
is $authorize->{authorize}->{loginid}, $cr_1;
$t = $t->send_ok({json => {tnc_approval => 1}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{error}->{code}, 'PermissionDenied', 'PermissionDenied b/c it is read';

$t->finish_ok;

done_testing();
