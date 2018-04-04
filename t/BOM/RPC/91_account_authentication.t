use strict;
use warnings;

use Test::Most;
use Test::Mojo;

use BOM::User;
use BOM::Platform::Password;
use BOM::Database::Model::AccessToken;
use BOM::Test::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase;

my ($t, $rpc_ct);
my $params = {
    language => 'EN',
    source   => 1,
    country  => 'in',
    args     => {},
};
my ($method, $email, $client_cr, $user, $token) = ('account_authentication');

subtest 'Initialization' => sub {
    lives_ok {
        $t = Test::Mojo->new('BOM::RPC');
        $rpc_ct = BOM::Test::RPC::Client->new(ua => $t->app->ua);

        $email = 'dummy' . rand(999) . '@binary.com';

        $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => $email
        });

        $user = BOM::User->create(
            email    => $email,
            password => BOM::Platform::Password::hashpw('a1b2c3D4'));
        $user->email_verified(1);
        $user->save;

        $user->add_loginid({loginid => $client_cr->loginid});
        $user->save;

        $token = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'test token');

    }
    'Initial RPC Client and other parameters';

    $params->{token} = $token;
    $params->{args}->{totp} = 'status';

    my $result = $rpc_ct->call_ok($method, $params)->has_no_system_error->result;
    is_deeply($result->{totp}, {"status" => 0}, 'Status should be 0');
};

subtest 'Generate Secret Key' => sub {
    is 1, 1, 'Dummy Test';
};

subtest 'Enable / Disable' => sub {
    is 1, 1, 'Dummy Test';
};

sub _call_status {
}

sub _call_generate {
}

sub _call_enable {
}

sub _call_disable {
}

done_testing();
