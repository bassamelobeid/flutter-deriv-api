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

subtest multiscope => sub {
    #testing with static token, 
    
    # Balance is allowed for both read and trading_information scopes. 
    
    # No scope access to balance
    my $token = BOM::Platform::Token::API->new->create_token($cr_1, 'Test', ['admin', 'trade']);
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;
    my $authorize = $json->decode(Encode::decode_utf8($t->message->[1]));
    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = $json->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, 'PermissionDenied', 'PermissionDenied Balance requires read or trading_information ';

    # Trading_information token for balance
    my $token_trading_info = BOM::Platform::Token::API->new->create_token($cr_1, 'trading_info', ['trading_information']);
    $t = $t->send_ok({json => {authorize => $token_trading_info}})->message_ok;
    $authorize = $json->decode(Encode::decode_utf8($t->message->[1]));
    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = $json->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, undef , 'Balance OK with trading_information scope';

    #token read for balance
    my $token_read = BOM::Platform::Token::API->new->create_token($cr_1, 'read_only', ['read']);
    $t = $t->send_ok({json => {authorize => $token_read}})->message_ok;
    $authorize = $json->decode(Encode::decode_utf8($t->message->[1]));
    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = $json->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, undef , 'Balance OK with read  scope';

    #Both read and trading_information
    my $token_read_info = BOM::Platform::Token::API->new->create_token($cr_1, 'read_and_info', ['read', 'trading_information']);
    $t = $t->send_ok({json => {authorize => $token_read_info}})->message_ok;
    $authorize = $json->decode(Encode::decode_utf8($t->message->[1]));
    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = $json->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, undef , 'Balance OK with read and trading_informaton scope';
   
    #One valid and 1 invalid scope for balance.  
    my $token_read_trade = BOM::Platform::Token::API->new->create_token($cr_1, 'read_and_trade', ['read', 'trade']);
    $t = $t->send_ok({json => {authorize => $token_read_trade}})->message_ok;
    $authorize = $json->decode(Encode::decode_utf8($t->message->[1]));
    $t = $t->send_ok({json => {balance => 1}})->message_ok;
    $res = $json->decode(Encode::decode_utf8($t->message->[1]));
    is $res->{error}->{code}, undef , 'Balance OK with read and trade scope';
};

$t->finish_ok;

done_testing();
