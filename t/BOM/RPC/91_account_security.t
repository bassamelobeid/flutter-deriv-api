use strict;
use warnings;

use Test::Most;
use Test::Mojo;

use Authen::OATH;
use Convert::Base32;
use BOM::User;
use BOM::User::Password;
use BOM::Platform::Token::API;
use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Email::Stuffer::TestLinks;

my ($t, $rpc_ct);
my $params = {
    language => 'EN',
    source   => 1,
    country  => 'in',
    args     => {},
};
my $method = ('account_security');
my ($email, $client_cr, $user, $token);

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC::Transport::HTTP');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);

        $email = 'dummy@binary.com';

        $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => $email
        });

        $user = BOM::User->create(
            email          => $email,
            password       => BOM::User::Password::hashpw('a1b2c3D4'),
            email_verified => 1
        );
        $user->add_client($client_cr);

        $token = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token');

    }
    'Initial RPC Client and other parameters';

    my $result = _call_status();
    is_deeply($result->{totp}, {'is_enabled' => 0}, 'Status should be 0');
};

subtest 'Two Factor Authentication Functionality' => sub {
    my ($result, $secret_key, $oath, $oath_totp);
    $oath = Authen::OATH->new();

    # Enable should not work if OTP is Wrong
    $result = _call_enable('123456');
    is($result->{error}->{code}, 'InvalidOTP', 'Enable should fail with wrong OTP');

    # Secret Key should be generated
    $result     = _call_generate();
    $secret_key = decode_base32($result->{totp}->{secret_key});
    is(length($secret_key) > 0, 1, 'Secret Key should be generated');

    # If OTP is correct, 2FA should be enabled
    $oath_totp = $oath->totp($secret_key);
    $result    = _call_enable($oath_totp);
    is_deeply($result->{totp}, {'is_enabled' => 1}, 'Should be enabled with correct OTP');

    # If already enabled, request to enable should fail
    $result = _call_enable($oath_totp);
    is($result->{error}->{code}, 'InvalidRequest', 'Enable should fail if already enabled');

    # If already enabled, request to generate secret key should fail
    $result = _call_generate();
    is($result->{error}->{code}, 'InvalidRequest', 'Generate should fail if already enabled');

    # Disable should not work if OTP is Wrong
    $result = _call_disable('123456');
    is($result->{error}->{code}, 'InvalidOTP', 'Disable should fail with wrong OTP');

    # If OTP is correct and 2FA is enabled request to disable should succeed
    $oath_totp = $oath->totp($secret_key);
    $result    = _call_disable($oath_totp);
    is_deeply($result->{totp}, {'is_enabled' => 0}, 'Should be disabled with correct OTP');

    # Disable should not work as it is already disabled
    $result = _call_disable('123456');
    is($result->{error}->{code}, 'InvalidRequest', 'Disable should fail if already disabled');
};

sub _call_status {
    $params->{token} = $token;
    $params->{args}->{totp_action} = 'status';

    return $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
}

sub _call_generate {
    $params->{token} = $token;
    $params->{args}->{totp_action} = 'generate';

    return $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
}

sub _call_enable {
    my $otp = shift;
    $params->{token}               = $token;
    $params->{args}->{totp_action} = 'enable';
    $params->{args}->{otp}         = $otp;

    return $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
}

sub _call_disable {
    my $otp = shift;
    $params->{token}               = $token;
    $params->{args}->{totp_action} = 'disable';
    $params->{args}->{otp}         = $otp;

    return $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
}

done_testing();
