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
use BOM::User::Client;
use BOM::Database::Model::OAuth;
use BOM::User::Password;

my $email    = 'dummy@binary.com';
my $password = 'jskjd8292922';

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;
my $json = JSON::MaybeXS->new;

my $user = BOM::User->create(
    email    => $email,
    password => $password,
);
$user->add_client($test_client);

is $test_client->default_account, undef, 'new client has no default account';

my $t = build_wsapi_test();

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $res = $json->decode(Encode::decode_utf8($t->message->[1]));
note explain $res;
is $res->{authorize}->{email}, 'dummy@binary.com', 'Correct email for session cookie token';
test_schema('authorize', $res);

$t = $t->send_ok({json => {set_account_currency => 'not_allowed'}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{error}->{code}, 'InputValidationFailed', 'Not in allowed list of currency';

$t = $t->send_ok({json => {set_account_currency => 'JPY'}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{error}->{code}, 'CurrencyTypeNotAllowed', 'Currency not applicable for this client';
is $res->{error}->{message}, 'The provided currency JPY is not applicable for this account.', 'Correct error message for invalid currency';

$t = $t->send_ok({json => {set_account_currency => 'EUR'}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{set_account_currency}, 1, 'Default currency set properly';

$t = $t->send_ok({json => {set_account_currency => 'USD'}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{set_account_currency}, 1, 'Can set default currency again if no deposit yet';

$test_client = BOM::User::Client->new({loginid => $test_client->loginid});
ok $test_client->default_account, 'Default account set correctly';
is $test_client->currency, 'USD', 'Got correct client currency after setting account';

$test_client->payment_doughflow(
    currency => 'USD',
    amount   => 1000,
    remark   => 'first deposit',
);

$t = $t->send_ok({json => {set_account_currency => 'GBP'}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
ok $res->{error}, 'Cannot change currency after deposit has been made';

# clear oauth token
$t = $t->send_ok({json => {logout => 1}})->message_ok;

done_testing();
