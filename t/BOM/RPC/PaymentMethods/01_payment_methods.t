use strict;
use warnings;

use BOM::User;
use RedisDB;

# test dependencies
use Test::MockModule;
use Test::Most;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;

require Test::NoWarnings;

my $rpc_ct;
subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

my $email          = 'dummy' . rand(999) . '@binary.com';
my $user_client_cr = BOM::User->create(
    email          => 'cr@binary.com',
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    place_of_birth => 'id',
    residence      => 'br',
});
$client_cr->set_default_account('USD');

$user_client_cr->add_client($client_cr);

subtest 'PaymentMethods' => sub {
    my $params = {};
    $params->{args}->{payment_methods} = 1;
    $params->{args}->{country}         = '';

    $rpc_ct->call_ok('payment_methods', $params)->has_no_system_error->has_no_error;

    $params->{args}->{country} = 'br';

    $rpc_ct->call_ok('payment_methods', $params)->has_no_system_error->has_no_error;

    # authenticated account
    $params->{country} = '';
    $params->{token}   = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token123');
    $rpc_ct->call_ok('payment_methods', $params)->has_no_system_error->has_no_error;
};

done_testing();

