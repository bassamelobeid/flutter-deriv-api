use strict;
use warnings;

use Test::Most;
use Test::MockModule;
use Test::Deep;

use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );
use Test::BOM::RPC::QueueClient;

my $c = Test::BOM::RPC::QueueClient->new();

my $hash_pwd = BOM::User::Password::hashpw('Abcd1234');

my $email = 'abcd@deriv.com';
my $user  = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'VRTC',
    binary_user_id => $user->id,
});
$client_vr->email($email);
$client_vr->save;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user->id,
});
$client->set_default_account('USD');
$client->email($email);
$client->save;

$user->add_client($client_vr);
$user->add_client($client);

my $method = 'tnc_approval';

subtest 'Affiliate Code of Conduct agreement approval' => sub {
    my $token = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);
    is(
        $c->tcall(
            $method,
            {
                token => $token,
            }
        )->{error}{message_to_client},
        'Permission denied.',
        'permission error for virtual accounts'
    );

    $token = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);
    is(
        $c->tcall(
            $method,
            {
                token => $token,
                args  => {
                    tnc_approval            => 1,
                    affiliate_coc_agreement => 1,
                },
            }
        )->{error}{message_to_client},
        'You have not registered as an affiliate.',
        'permission error for non-affiliate user'
    );

    $client->user->set_affiliate_id('Aff123');
    is $client->user->affiliate->{affiliate_id}, 'Aff123', 'registered as an affiliate';

    is(
        $c->tcall(
            $method,
            {
                token => $token,
                args  => {
                    tnc_approval            => 1,
                    affiliate_coc_agreement => 1,
                },
            }
        )->{status},
        1,
        'tnc_approval rpc returns ok'
    );

    $client->user->affiliate->{code_of_conduct_approval}, 1, 'coc is accepted';
};

done_testing;
