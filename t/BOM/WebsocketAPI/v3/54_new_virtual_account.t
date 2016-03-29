use strict;
use warnings;
use Test::More tests => 7;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use List::Util qw(first);
use RateLimitations qw (flush_all_service_consumers);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token::Verification;
use BOM::System::RedisReplicated;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my $t     = build_mojo_test();
my $email = 'test@binary.com';

subtest 'verify_email' => sub {
    $t = $t->send_ok({
            json => {
                verify_email => $email,
                type         => 'some_garbage_value'
            }})->message_ok;
    my $res = decode_json($t->message->[1]);
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

    # send this again to check if invalidates old one
    $t = $t->send_ok({
            json => {
                verify_email => $email,
                type         => 'account_opening'
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    is($res->{verify_email}, 1, 'verify_email OK');
    test_schema('verify_email', $res);
    ok _get_token(), "Token exists";

    is(BOM::Platform::Token::Verification->new({token => $old_token})->token, undef, 'New token will expire old token created earlier');
};

my $create_vr = {
    new_account_virtual => 1,
    client_password     => 'Ac0+-_:@.',
    residence           => 'au',
    verification_code   => 'laskdjfalsf12081231'};

subtest 'create Virtual account' => sub {
    $t = $t->send_ok({json => $create_vr})->message_ok;
    my $res = decode_json($t->message->[1]);
    is($res->{error}->{code}, 'InvalidToken', 'wrong token');

    # as verify_email has rate limit, so clearing for testing other cases also
    flush_all_service_consumers();

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
    ok($res->{new_account_virtual});
    test_schema('new_account_virtual', $res);

    like($res->{new_account_virtual}->{client_id}, qr/^VRTC/, 'got VRTC client');
    is($res->{new_account_virtual}->{currency}, 'USD', 'got currency');
    cmp_ok($res->{new_account_virtual}->{balance}, '==', '10000', 'got balance');
};

subtest 'Invalid email verification code' => sub {
    $t = $t->send_ok({json => $create_vr})->message_ok;
    my $res = decode_json($t->message->[1]);

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
    my $redis = BOM::System::RedisReplicated::redis_read;
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
