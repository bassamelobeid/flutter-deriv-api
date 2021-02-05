use strict;
use warnings;
use Test::More;
use JSON::MaybeXS;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request reconnect/;
use BOM::Platform::Token;
use BOM::Config::Redis;
use List::Util qw(first);

use await;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

# We don't want to fail due to hitting limits
$ENV{BOM_TEST_RATE_LIMITATIONS} = '/home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/rate_limitations.yml';

## do not send email
use Test::MockObject;
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $t     = build_wsapi_test();
my $email = 'test1@binary.com';

subtest 'verify_email' => sub {
    my $res = $t->await::verify_email({
        verify_email => $email,
        type         => 'some_garbage_value'
    });
    is($res->{msg_type}, 'verify_email');
    is($res->{error}->{code}, 'InputValidationFailed', 'verify_email failed');
    is($res->{msg_type},      'verify_email',          'Message type is correct in case of error');
    test_schema('verify_email', $res);

    $res = $t->await::verify_email({
        verify_email => 'test@binary.com(<svg/onload=alert(1)>)',
        type         => 'account_opening'
    });
    is($res->{msg_type}, 'verify_email');
    is($res->{error}->{code}, 'InputValidationFailed', 'verify_email failed');
    like($res->{error}->{details}{verify_email}, qr/String does not match/, 'validation of email address failed');
    like($res->{error}->{message},               qr/verify_email/,          'error message contains the problematic field');
    is($res->{msg_type}, 'verify_email', 'Message type is correct in case of error');
    test_schema('verify_email', $res);

    $res = $t->await::verify_email({
        verify_email => $email,
        type         => 'account_opening'
    });
    is($res->{verify_email}, 1, 'verify_email OK');
    test_schema('verify_email', $res);

    my $old_token = _get_token($email);

    my (undef, $call_params) = call_mocked_consumer_groups_request(
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
    $res = $t->await::verify_email({
        verify_email => $email,
        type         => 'account_opening'
    });
    is($res->{verify_email}, 1, 'verify_email OK');
    test_schema('verify_email', $res);
    ok _get_token($email), "Token exists";

    is(BOM::Platform::Token->new({token => $old_token})->token, undef, 'New token will expire old token created earlier');
};

my $create_vr = {
    new_account_virtual => 1,
    client_password     => 'Ac0+-_:@.',
    residence           => 'au',
    verification_code   => 'laskdjfalsf12081231',
    email_consent       => 1,
};

subtest 'email and password likeness' => sub {
    my $res = $t->await::verify_email({
        verify_email => $email,
        type         => 'account_opening'
    });
    is($res->{verify_email}, 1, 'verify_email OK');

    my %create_vr_clone = $create_vr->%*;

    $create_vr_clone{verification_code} = _get_token($email);
    $create_vr_clone{client_password}   = 'Test1@binary.com';

    $res = $t->await::new_account_virtual(\%create_vr_clone);

    is($res->{error}->{code},       'PasswordError',                                       'New password cannot be the same as your email.');
    is($res->{error}->{message},    'You cannot use your email address as your password.', 'Message to client is correct');
    is($res->{new_account_virtual}, undef,                                                 'NO account created');
};

subtest 'create Virtual account' => sub {
    my $res = $t->await::new_account_virtual($create_vr);
    is($res->{error}->{code}, 'InvalidToken', 'wrong token');

    $res = $t->await::verify_email({
        verify_email => $email,
        type         => 'account_opening'
    });
    is($res->{verify_email}, 1, 'verify_email OK');

    $create_vr->{verification_code} = _get_token($email);

    $res = $t->await::new_account_virtual($create_vr);
    is($res->{msg_type}, 'new_account_virtual');
    ok($res->{new_account_virtual});
    test_schema('new_account_virtual', $res);

    like($res->{new_account_virtual}->{client_id}, qr/^VRTC/, 'got VRTC client');
    is($res->{new_account_virtual}->{currency}, 'USD', 'got currency');
    cmp_ok($res->{new_account_virtual}->{balance}, '==', '10000', 'got balance');

    my $user = BOM::User->new(email => $email);
    ok $user->email_consent, 'Email consent flag set';
};

my $create_vr2 = {
    new_account_virtual => 1,
    client_password     => 'Ac0+-_:@.',
    residence           => 'au',
    verification_code   => 'laskdjfalsf12081231',
    email_consent       => 0,
};

my $email2 = 'test2@binary.com';

subtest 'create Virtual account wihtout consent flag' => sub {
    my $res = $t->await::verify_email({
        verify_email => $email2,
        type         => 'account_opening'
    });
    is($res->{verify_email}, 1, 'verify_email OK');
    test_schema('verify_email', $res);

    $res = $t->await::verify_email({
        verify_email => $email2,
        type         => 'account_opening'
    });
    is($res->{verify_email}, 1, 'verify_email OK');

    $create_vr2->{verification_code} = _get_token($email2);

    $res = $t->await::new_account_virtual($create_vr2);

    is($res->{msg_type}, 'new_account_virtual');
    ok($res->{new_account_virtual});
    test_schema('new_account_virtual', $res);

    like($res->{new_account_virtual}->{client_id}, qr/^VRTC/, 'got VRTC client');
    is($res->{new_account_virtual}->{currency}, 'USD', 'got currency');
    cmp_ok($res->{new_account_virtual}->{balance}, '==', '10000', 'got balance');

    my $user = BOM::User->new(email => $email2);
    ok !$user->email_consent, 'Email consent flag not set';
};

subtest 'Invalid email verification code' => sub {
    my $res = $t->await::new_account_virtual($create_vr);

    is($res->{msg_type}, 'new_account_virtual');
    is($res->{error}->{code},       'InvalidToken', 'wrong verification code');
    is($res->{new_account_virtual}, undef,          'NO account created');
};

subtest 'NO duplicate email' => sub {
    my $res = $t->await::verify_email({
        verify_email => $email,
        type         => 'account_opening'
    });
    is($res->{verify_email}, 1, 'verify_email OK');
    test_schema('verify_email', $res);

    $create_vr->{verification_code} = _get_token($email);
    $res = $t->await::new_account_virtual($create_vr);

    is($res->{error}->{code},       'duplicate email', 'duplicate email err code');
    is($res->{new_account_virtual}, undef,             'NO account created');
};

subtest 'insufficient data' => sub {
    delete $create_vr->{residence};

    my $res = $t->await::new_account_virtual($create_vr);
    is($res->{error}->{code},       'InputValidationFailed', 'insufficient input');
    is($res->{new_account_virtual}, undef,                   'NO account created');
};

sub _get_token {
    my ($email) = @_;
    my $redis   = BOM::Config::Redis::redis_replicated_read();
    my $tokens  = $redis->execute('keys', 'VERIFICATION_TOKEN::*');

    my $code;
    my $json = JSON::MaybeXS->new;
    foreach my $key (@{$tokens}) {
        my $value = $json->decode(Encode::decode_utf8($redis->get($key)));

        if ($value->{email} eq $email) {
            $key =~ /^VERIFICATION_TOKEN::(\w+)$/;
            $code = $1;
            last;
        }
    }
    return $code;
}

$t->finish_ok;

done_testing;
