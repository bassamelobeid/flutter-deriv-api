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
        $t      = Test::Mojo->new('BOM::RPC::Transport::HTTP');
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

my ($secret_key, $oath_totp) = '';
my $oath = Authen::OATH->new();

subtest 'Generate TOTP secret key' => sub {
    my $result          = _call_generate();
    my $temp_secret_key = decode_base32($result->{totp}->{secret_key});
    is(length($temp_secret_key) > 0, 1, 'Secret Key generated.');

    $result     = _call_generate();
    $secret_key = decode_base32($result->{totp}->{secret_key});
    ok($secret_key ne $temp_secret_key, 'Secret key is different with previous key');
};

subtest 'Enable 2FA' => sub {
    my $result = _call_enable('123456');
    is($result->{error}->{code}, 'InvalidOTP', 'Enable failed due to wrong OTP');

    $result     = _call_generate();
    $secret_key = decode_base32($result->{totp}->{secret_key});
    is(length($secret_key) > 0, 1, 'Secret key generated');

    $oath_totp = $oath->totp($secret_key);
    $result    = _call_enable($oath_totp);
    is_deeply($result->{totp}, {'is_enabled' => 1}, '2FA enabled');

    $result = _call_enable($oath_totp);
    is($result->{error}->{code}, 'InvalidRequest', 'Enable failed due to already enabled 2FA');

    $result = _call_generate();
    is($result->{error}->{code}, 'InvalidRequest', 'Generate failed due to already enabled 2FA');
};

subtest 'Disable 2FA' => sub {
    my $result = _call_disable('123456');
    is($result->{error}->{code}, 'InvalidOTP', 'Disable failed due to wrong OTP');

    $oath_totp = $oath->totp($secret_key);
    $result    = _call_disable($oath_totp);
    is_deeply($result->{totp}, {'is_enabled' => 0}, '2FA disabled');

    $result = _call_disable('123456');
    is($result->{error}->{code}, 'InvalidRequest', 'Disable failed due to already enabled 2FA');
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
