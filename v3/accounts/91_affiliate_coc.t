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

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

$client->email($email);
$client->save;

$user->add_client($client);

$user->set_affiliate_id('aff123');

subtest 'Affiliate Code of Conduct agreement approval' => sub {
    my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

    $t->await::authorize({authorize => $token});

    my $res = $t->await::tnc_approval({
        tnc_approval            => 1,
        affiliate_coc_agreement => 1
    });

    ok($res->{tnc_approval});
    test_schema('tnc_approval', $res);
};

$t->finish_ok;

done_testing;
