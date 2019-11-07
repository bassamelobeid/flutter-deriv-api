#!perl

use strict;
use warnings;
use Test::More;
use utf8;
use Test::Exception;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use JSON::MaybeUTF8 qw(:v1);
use await;

my $t = build_wsapi_test();

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($client);

$client->set_default_account('USD');

# check for authenticated call
my $response = $t->await::transaction({
    transaction => 1,
    subscribe   => 1
});
is $response->{error}->{code},    'AuthorizationRequired';
is $response->{error}->{message}, 'Please log in.';

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $loginid;

# wrong call - no subscribe
$response = $t->await::transaction({transaction => 1});
$client->smart_payment(
    currency     => 'USD',
    amount       => +100,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

is $response->{error}->{code}, 'InputValidationFailed';

$response = $t->await::transaction({
    transaction => 1,
    subscribe   => 1
});
ok my $uuid = $response->{transaction}->{id}, 'There is an ID';
is $response->{subscription}->{id}, $uuid, 'It is equal to subscription id';
test_schema('transaction', $response);

$response = $t->await::transaction({
    transaction => 1,
    subscribe   => 1
});
cmp_ok $response->{msg_type},, 'eq', 'transaction';
cmp_ok $response->{error}->{code}, 'eq', 'AlreadySubscribed', 'AlreadySubscribed error expected';

# NOTICE I don't know why, but if I want to get the stream message, I must send a wrong websocket command
# otherwise I cannot get the following message.
$t->await::something({});

$client->smart_payment(
    currency     => 'USD',
    amount       => +100,
    payment_type => 'external_cashier',
    remark       => '存钱'
);

# Here we test the message process flow when json include utf8 string.
lives_ok { $response = $t->await::transaction() } "utf8 string is ok";
is $response->{transaction}->{id},  $uuid, 'The same id';
is $response->{subscription}->{id}, $uuid, 'The same subscription id';
test_schema('transaction', $response);

$response = $t->await::forget_all({forget_all => 'transaction'});
is scalar @{$response->{forget_all}}, 1, 'Correct number of ids';
is $response->{forget_all}->[0], $uuid, 'Correct id value';
test_schema('forget_all', $response);

done_testing();
