use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_mojo_test/;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

# Hack to get stash values, can't use hook after dispatch, because we should check value after wss message
my $stash  = {};
my $module = Test::MockModule->new('Mojolicious::Controller');
$module->mock(
    'stash',
    sub {
        my (undef, @params) = @_;
        if (@params > 1 || ref $params[0]) {
            my $values = ref $params[0] ? $params[0] : {@params};
            @$stash{keys %$values} = values %$values;
        }
        Mojo::Util::_stash(stash => @_);
    });

my $t = build_mojo_test();

## test those requires auth
$t = $t->send_ok({json => {balance => 1}})->message_ok;
my $balance = decode_json($t->message->[1]);
is($balance->{error}->{code}, 'AuthorizationRequired');
test_schema('balance', $balance);

## test with faked token
my $faked_token = 'ABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCD';
$t = $t->send_ok({json => {authorize => $faked_token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{msg_type}, 'authorize';
is $authorize->{error}->{code}, 'InvalidToken';
test_schema('authorize', $authorize);

## test with good one

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

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
$authorize = decode_json($t->message->[1]);
is $authorize->{msg_type}, 'authorize';
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $loginid;
is $authorize->{authorize}->{country}, 'id', 'return correct country';
test_schema('authorize', $authorize);
is $stash->{loginid}, $loginid, 'Test stash data';
is $stash->{email},   $email,   'Should store email to stash';
is $stash->{token},   $token,   'Should store token to stash';
is $stash->{token_type}, 'oauth_token', 'Should store token_type to stash';
is_deeply $stash->{scopes}, [qw/read admin trade payments/], 'Should store token_scopes to stash';
ok $stash->{account_id},           'Should store to account_id stash';
ok $stash->{country},              'Should store country to stash';
ok $stash->{currency},             'Should store currency to stash';
ok $stash->{landing_company_name}, 'Should store landing_company_name to stash';
ok exists $stash->{is_virtual}, 'Should store is_virtual to stash';
ok !$authorize->{authorize}->{account_id}, 'Shouldnt return account_id';

## it's ok after authorize
$t = $t->send_ok({json => {balance => 1}})->message_ok;
$balance = decode_json($t->message->[1]);
ok($balance->{balance});
test_schema('balance', $balance);

## try logout
$t = $t->send_ok({json => {logout => 1}})->message_ok;
my $res = decode_json($t->message->[1]);
is $res->{msg_type}, 'logout';
is $res->{logout},   1;
test_schema('logout', $res);
ok exists $stash->{loginid} && !defined $stash->{loginid},              'Should remove loginid from stash';
ok exists $stash->{loginid} && !defined $stash->{email},                'Should remove email from stash';
ok exists $stash->{loginid} && !defined $stash->{token},                'Should remove token from stash';
ok exists $stash->{loginid} && !defined $stash->{token_type},           'Should remove token_type from stash';
ok exists $stash->{loginid} && !defined $stash->{account_id},           'Should remove account_id from stash';
ok exists $stash->{loginid} && !defined $stash->{currency},             'Should remove currency from stash';
ok exists $stash->{loginid} && !defined $stash->{landing_company_name}, 'Should remove landing_company_name from stash';

$t = $t->send_ok({json => {balance => 1}})->message_ok;
$balance = decode_json($t->message->[1]);
is($balance->{error}->{code}, 'AuthorizationRequired', 'required again after logout');

$t->finish_ok;

done_testing();
