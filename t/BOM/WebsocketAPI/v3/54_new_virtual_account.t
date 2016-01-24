use strict;
use warnings;
use Test::More tests => 7;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use BOM::Platform::SessionCookie;
use BOM::System::RedisReplicated;
use List::Util qw(first);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my $t = build_mojo_test();

my $email = 'test@binary.com';

subtest 'verify_email' => sub {
    $t = $t->send_ok({
            json => {
                verify_email => $email,
                type         => 'account_opening'
            }})->message_ok;
    my $res = decode_json($t->message->[1]);
    is($res->{verify_email}, 1, 'verify_email OK');
    test_schema('verify_email', $res);
};

my $redis = BOM::System::RedisReplicated::redis_read;
my $tokens = $redis->execute('keys', 'LOGIN_SESSION::*');

my $code;
foreach my $key (@{$tokens}) {
    my $value = JSON::from_json($redis->get($key));

    if ($value->{email} eq $email) {
        $key =~ /^LOGIN_SESSION::(\w+)$/;
        $code = $1;
        last;
    }
}

my $create_vr = {
    new_account_virtual => 1,
    email               => $email,
    client_password     => 'Ac0+-_:@.',
    residence           => 'au',
    verification_code   => $code
};

subtest 'create Virtual account' => sub {
    $t = $t->send_ok({json => $create_vr})->message_ok;
    my $res = decode_json($t->message->[1]);
    ok($res->{new_account_virtual});
    test_schema('new_account_virtual', $res);

    like($res->{new_account_virtual}->{client_id}, qr/^VRTC/, 'got VRTC client');
    is($res->{new_account_virtual}->{currency}, 'USD', 'got currency');
    cmp_ok($res->{new_account_virtual}->{balance}, '==', '10000', 'got balance');
};

subtest 'Invalid email verification code' => sub {
    $create_vr->{email} = 'test123@binary.com';

    $t = $t->send_ok({json => $create_vr})->message_ok;
    my $res = decode_json($t->message->[1]);

    is($res->{error}->{code}, 'email unverified', 'Email unverified as wrong verification code');
    is($res->{new_account_virtual}, undef, 'NO account created');
};

subtest 'NO duplicate email' => sub {
    $create_vr->{email} = $email;

    $t = $t->send_ok({json => $create_vr})->message_ok;
    my $res = decode_json($t->message->[1]);

    is($res->{error}->{code},       'duplicate email', 'duplicate email err code');
    is($res->{new_account_virtual}, undef,             'NO account created');
};

subtest 'insufficient data' => sub {
    delete $create_vr->{residence};

    $t = $t->send_ok({json => $create_vr})->message_ok;
    my $res = decode_json($t->message->[1]);

    is($res->{error}->{code}, 'InputValidationFailed', 'insufficient input');
    is($res->{new_account_virtual}, undef, 'NO account created');
};

$t->finish_ok;
