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

use BOM::Platform::Account::Virtual;
use BOM::Database::Model::OAuth;
use BOM::Config::Redis;
use await;

my $t = build_wsapi_test();
my ($vr_client, $user) = create_vr_account({
    email           => 'pnv+challenge@deriv.com',
    client_password => 'secret_pwd',
});

my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

$user->add_client($client_cr);

my ($token_cr) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_cr->loginid);
$t->await::authorize({authorize => $token_cr});

subtest 'generate an otp' => sub {
    my $expected_response_object = {phone_number_challenge => 1};

    my $res = $t->await::phone_number_challenge({phone_number_challenge => 1, carrier => 'whatsapp'});
    test_schema('phone_number_challenge', $res);

    cmp_deeply $res->{phone_number_challenge}, 1, 'Expected response object';
};

# ttl of the redis key is 10 minutes, if this test ever becomes flaky then our real problem would be the ci speed :)
subtest 'too soon to generate another one' => sub {
    my $res = $t->await::phone_number_challenge({phone_number_challenge => 1, carrier => 'sms'});
    test_schema('phone_number_challenge', $res);

    cmp_deeply $res->{error},
        {
        code    => 'NoAttemptsLeft',
        message => 'Please wait for some time before requesting another OTP code'
        },
        'Expected error message';
};

subtest 'already verified accounts should not apply' => sub {
    $user->pnv->update(1);

    my $res = $t->await::phone_number_challenge({phone_number_challenge => 1, carrier => 'sms'});
    test_schema('phone_number_challenge', $res);

    cmp_deeply $res->{error},
        {
        code    => 'AlreadyVerified',
        message => 'This account is already phone number verified'
        },
        'Expected error message';
};

sub create_vr_account {
    my $args = shift;
    my $acc  = BOM::Platform::Account::Virtual::create_account({
            details => {
                email           => $args->{email},
                client_password => $args->{client_password},
                account_type    => 'binary',
                residence       => 'br',
                email_verified  => 1,
            },
        });

    return ($acc->{client}, $acc->{user});
}

$t->finish_ok;

done_testing;
