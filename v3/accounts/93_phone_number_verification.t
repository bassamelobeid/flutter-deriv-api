use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use BOM::User::PhoneNumberVerification;
use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;
use BOM::Config::Redis;
use await;

my $t = build_wsapi_test();

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'pnv+challenge@deriv.com',
});

my ($vr_client, $user) = create_vr_account({
    email           => 'pnv+challenge@deriv.com',
    client_password => 'secret_pwd',
});

$user->add_client($client_cr);
$client_cr->user($user);
$client_cr->binary_user_id($user->id);
$client_cr->save;

my ($token_cr) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr->loginid);
$t->await::authorize({authorize => $token_cr});

subtest 'generate an email' => sub {
    my $email_code = get_email_code();

    ok $email_code, 'there is an email code';

    my $raw = get_email_code({
        raw => 1,
    });

    is $raw->{error}->{code}, 'NoAttemptsLeft', 'Expected error code';
};

subtest 'attempted too many times' => sub {
    $user->pnv->increase_attempts() for (1 .. 10);

    my $email_code = get_email_code({
        reset_block => 1,
    });
    my $res = $t->await::phone_number_challenge({phone_number_challenge => 1, carrier => 'sms', email_code => $email_code});
    test_schema('phone_number_challenge', $res);

    cmp_deeply $res->{error},
        {
        code    => 'NoAttemptsLeft',
        message => 'Please wait for some time before requesting another OTP code'
        },
        'Expected error message';

    $user->pnv->clear_attempts;
};

subtest 'generate an otp' => sub {
    my $email_code = get_email_code({
        reset_block => 1,
    });

    my $res = $t->await::phone_number_challenge({phone_number_challenge => 1, carrier => 'whatsapp', 'email_code' => $email_code});
    test_schema('phone_number_challenge', $res);

    cmp_deeply $res->{phone_number_challenge}, 1, 'Expected response object';
};

subtest 'submit invalid otp' => sub {
    my $res = $t->await::phone_number_verify({phone_number_verify => 1, otp => 'BADOTP'});
    test_schema('phone_number_verify', $res);

    cmp_deeply $res->{error},
        {
        code    => 'InvalidOTP',
        message => 'The OTP is not valid'
        },
        'Expected error message';
};

subtest 'submit a valid otp' => sub {
    my $res = $t->await::phone_number_verify({phone_number_verify => 1, otp => $user->id . ''});
    test_schema('phone_number_verify', $res);

    cmp_deeply $res->{phone_number_verify}, 1, 'Expected response object';
};

subtest 'already verified accounts should not verify again' => sub {
    $user->pnv->update(1);

    my $res = $t->await::phone_number_verify({phone_number_verify => 1, otp => $user->id . ''});
    test_schema('phone_number_verify', $res);

    cmp_deeply $res->{error},
        {
        code    => 'AlreadyVerified',
        message => 'This account is already phone number verified'
        },
        'Expected error message';

    $user->pnv->update(0);
};

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                account_type    => 'binary',
                email_verified  => 1,
                residence       => 'br',
            },
        });

    return ($acc->{client}, $acc->{user});
}

sub get_email_code {
    my ($args) = @_;

    if ($args->{reset_block}) {
        my $redis = BOM::Config::Redis::redis_events_write();

        $redis->del(+BOM::User::PhoneNumberVerification::PNV_NEXT_EMAIL_PREFIX . $user->id);
    }

    my $res = $t->await::verify_email({
        verify_email => $client_cr->email,
        type         => 'phone_number_verification'
    });

    test_schema('verify_email', $res);

    if ($args->{raw}) {
        return $res;
    }

    cmp_deeply $res->{verify_email}, 1, 'Expected response object';

    my $token = BOM::Config::Redis::redis_replicated_write()->keys('VERIFICATION_TOKEN::*');
    my $key   = shift @$token;
    my $code  = $key =~ s/VERIFICATION_TOKEN:://gr;

    return $code;
}

$t->finish_ok;

done_testing;
