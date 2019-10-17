use strict;
use warnings;
use Test::More;
use Encode;
use JSON::MaybeXS;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::User::Password;

my $email       = 'raunak@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::User::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

my $json         = JSON::MaybeXS->new;
my $test_loginid = $test_client->loginid;
my $user         = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->add_client($test_client);
$user->add_login_history(
    environment => 'dummy environment',
    successful  => 't',
    action      => 'logout',
    app_id      => '1098'
);

my $t = build_wsapi_test();

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_loginid);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{authorize}->{email}, 'raunak@binary.com', 'Correct email for oauth token';
test_schema('authorize', $res);

$t = $t->send_ok({json => {login_history => 1}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is scalar(@{$res->{login_history}}), 1, 'got correct number of login history records';
ok $res->{login_history}->[0]->{action},      'login history record has action key';
ok $res->{login_history}->[0]->{environment}, 'login history record has environment key';
ok $res->{login_history}->[0]->{time},        'login history record has time key';

# clear oauth token
$t = $t->send_ok({json => {logout => 1}})->message_ok;

done_testing();
