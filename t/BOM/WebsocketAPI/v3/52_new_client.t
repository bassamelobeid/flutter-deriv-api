use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::System::Password;
use BOM::Platform::User;
use BOM::Platform::Client;

my $t = build_mojo_test();

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::System::Password::hashpw($password);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client_vr->email($email);
$client_vr->save;
$client_cr->email($email);
$client_cr->save;
my $vr_1 = $client_vr->loginid;
my $cr_1 = $client_cr->loginid;

my $user = BOM::Platform::User->create(
    email    => $email,
    password => $hash_pwd
);
$user->save;

$user->add_loginid({loginid => $vr_1});
$user->add_loginid({loginid => $cr_1});
$user->save;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $vr_1,
    email   => $email,
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $vr_1;

## test statement
$t = $t->send_ok({
        json => {
            statement => 1,
            limit     => 1
        }})->message_ok;
my $statement = decode_json($t->message->[1]);
ok($statement->{statement});
is($statement->{statement}->{count}, 0);
is_deeply $statement->{statement}->{transactions}, [];
test_schema('statement', $statement);

## test profit table
$t = $t->send_ok({
        json => {
            profit_table => 1,
            limit        => 1,
        }})->message_ok;
my $profit_table = decode_json($t->message->[1]);
ok($profit_table->{profit_table});
is($profit_table->{profit_table}->{count}, 0);
is_deeply $profit_table->{profit_table}->{transactions}, [];
test_schema('profit_table', $profit_table);

## test disabled
$client_vr->set_status('disabled', 'test.t', "just for test");
$client_vr->save();
$t = $t->send_ok({
        json => {
            profit_table => 1,
            limit        => 1,
        }})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'DisabledClient', 'you can not call any authenticated api after disabled.';

$t->finish_ok;

done_testing();
