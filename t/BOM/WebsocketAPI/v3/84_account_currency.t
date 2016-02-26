use strict;
use warnings;
use Test::More;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Platform::User;
use BOM::Platform::Client;
use BOM::Platform::SessionCookie;
use BOM::System::Password;

my $email       = 'dummy@binary.com';
my $password    = 'jskjd8292922';
my $hash_pwd    = BOM::System::Password::hashpw($password);
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;

is $test_client->default_account, undef, 'new client has no default account';

my $t     = build_mojo_test();
my $token = BOM::Platform::SessionCookie->new(
    loginid => $test_client->loginid,
    email   => $email
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{authorize}->{email}, 'dummy@binary.com', 'Correct email for session cookie token';
test_schema('authorize', $res);

$t = $t->send_ok({json => {set_account_currency => 'not_allowed'}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'InputValidationFailed', 'Not in allowed list of currency';

$t = $t->send_ok({json => {set_account_currency => 'JPY'}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{error}->{code}, 'InvalidCurrency', 'Currency not applicable for this client';
is $res->{error}->{message}, 'The provided currency JPY is not applicable for this account.', 'Correct error message for invalid currency';

$t = $t->send_ok({json => {set_account_currency => 'EUR'}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{set_account_currency}, 1, 'Default currency set properly';

$t = $t->send_ok({json => {set_account_currency => 'USD'}})->message_ok;
$res = decode_json($t->message->[1]);
is $res->{set_account_currency}, 0, 'Can not set default currency again';

$test_client = BOM::Platform::Client->new({loginid => $test_client->loginid});
ok $test_client->default_account, 'Default account set correctly';
is $test_client->currency, 'EUR', 'Got correct client currency after setting account';

# clear session token
$t = $t->send_ok({json => {logout => 1}})->message_ok;

done_testing();
