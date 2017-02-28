use strict;
use warnings;
use Test::More tests => 7;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client reconnect/;
use BOM::Platform::Token;
use BOM::Platform::RedisReplicated;
use List::Util qw(first);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

# We don't want to fail due to hitting limits
$ENV{BOM_TEST_RATE_LIMITATIONS} = '/home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/rate_limitations.yml';

## do not send email
use Test::MockObject;
use Test::MockModule;
my $client_mocked = Test::MockModule->new('Client::Account');
$client_mocked->mock('add_note', sub { return 1 });

my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my $t     = build_wsapi_test();
my $email = 'test@binary.com';

subtest 'verify_email' => sub {
    $t = $t->send_ok({
            json => {
                verify_email => $email,
                type         => 'some_garbage_value'
            }})->message_ok;
    my $res = decode_json($t->message->[1]);
    is($res->{msg_type}, 'verify_email');
    is($res->{error}->{code}, 'InputValidationFailed', 'verify_email failed');
    is($res->{msg_type},      'verify_email',          'Message type is correct in case of error');
    test_schema('verify_email', $res);

    $t = $t->send_ok({
            json => {
                verify_email => $email,
                type         => 'account_opening'
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    is($res->{verify_email}, 1, 'verify_email OK');
    test_schema('verify_email', $res);

    my $old_token = _get_token();

    my (undef, $call_params) = call_mocked_client(
        $t,
        {
            verify_email => $email,
            type         => 'account_opening'
        });
    is $call_params->{args}->{verify_email}, $email;
    ok $call_params->{args}->{type};
    ok $call_params->{server_name};

    # close session to invalidate hit limit
    reconnect($t);
    $t = $t->send_ok({
            json => {
                verify_email => $email,
                type         => 'account_opening'
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    is($res->{msg_type}, 'verify_email');
    is($res->{verify_email}, 1, 'verify_email OK');
    test_schema('verify_email', $res);
    ok _get_token(), "Token exists";

    is(BOM::Platform::Token->new({token => $old_token})->token, undef, 'New token will expire old token created earlier');
};

my $create_vr = {
    new_account_virtual => 1,
    client_password     => 'Ac0+-_:@.',
    residence           => 'au',
    verification_code   => 'laskdjfalsf12081231'
};

subtest 'create Virtual account' => sub {
    $t = $t->send_ok({json => $create_vr})->message_ok;
    my $res = decode_json($t->message->[1]);
    is($res->{error}->{code}, 'InvalidToken', 'wrong token');

    $t = $t->send_ok({
            json => {
                verify_email => $email,
                type         => 'account_opening'
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    is($res->{verify_email}, 1, 'verify_email OK');

    $create_vr->{verification_code} = _get_token();

    $t = $t->send_ok({json => $create_vr})->message_ok;
    $res = decode_json($t->message->[1]);
    is($res->{msg_type}, 'new_account_virtual');
    ok($res->{new_account_virtual});
    test_schema('new_account_virtual', $res);

    like($res->{new_account_virtual}->{client_id}, qr/^VRTC/, 'got VRTC client');
    is($res->{new_account_virtual}->{currency}, 'USD', 'got currency');
    cmp_ok($res->{new_account_virtual}->{balance}, '==', '10000', 'got balance');
};

subtest 'Invalid email verification code' => sub {
    $t = $t->send_ok({json => $create_vr})->message_ok;
    my $res = decode_json($t->message->[1]);

    is($res->{msg_type}, 'new_account_virtual');
    is($res->{error}->{code},       'InvalidToken', 'wrong verification code');
    is($res->{new_account_virtual}, undef,          'NO account created');
};

subtest 'NO duplicate email' => sub {
    $t = $t->send_ok({
            json => {
                verify_email => $email,
                type         => 'account_opening'
            }})->message_ok;
    my $res = decode_json($t->message->[1]);
    is($res->{verify_email}, 1, 'verify_email OK');
    test_schema('verify_email', $res);

    $create_vr->{verification_code} = _get_token();
    $t = $t->send_ok({json => $create_vr})->message_ok;
    $res = decode_json($t->message->[1]);

    is($res->{error}->{code},       'duplicate email', 'duplicate email err code');
    is($res->{new_account_virtual}, undef,             'NO account created');
};

subtest 'insufficient data' => sub {
    delete $create_vr->{residence};

    $t = $t->send_ok({json => $create_vr})->message_ok;
    my $res = decode_json($t->message->[1]);
    note explain $res;

    is($res->{error}->{code}, 'InputValidationFailed', 'insufficient input');
    is($res->{new_account_virtual}, undef, 'NO account created');
};

sub _get_token {
    my $redis = BOM::Platform::RedisReplicated::redis_read;
    my $tokens = $redis->execute('keys', 'VERIFICATION_TOKEN::*');

    my $code;
    foreach my $key (@{$tokens}) {
        my $value = JSON::from_json($redis->get($key));

        if ($value->{email} eq $email) {
            $key =~ /^VERIFICATION_TOKEN::(\w+)$/;
            $code = $1;
            last;
        }
    }
    return $code;
}

$t->finish_ok;
