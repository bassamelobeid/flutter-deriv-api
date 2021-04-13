use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::User::Password;
use BOM::User;
use BOM::User::Client;
use BOM::Platform::Account::Virtual;

use await;

my $t = build_wsapi_test();

my $email    = 'abc@binary.com';
my $password = 'jskjd8292922';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
$client_vr->save;

my $wallet_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRDW'});
$wallet_client_vr->save;

$user->add_client($client_vr);
$user->add_client($wallet_client_vr);

subtest 'link_wallet' => sub {
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_vr->loginid);

    $t->await::authorize({authorize => $token});

    my $res = $t->await::link_wallet({
        link_wallet => 1,
        wallet_id   => $wallet_client_vr->loginid,
        client_id   => $client_vr->loginid,
    });

    ok($res->{link_wallet});
    test_schema('link_wallet', $res);
};

$t->finish_ok;

done_testing;
