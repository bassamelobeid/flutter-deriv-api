use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::User;
use BOM::RPC::v3::Accounts;
use BOM::Database::Model::OAuth;
use utf8;
use Data::Dumper;

my $email       = 'dummy@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$test_client->email($email);
$test_client->save;
my $user = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $test_client->loginid});
$user->save;

my $oauth = BOM::Database::Model::OAuth->new;
my ($token) = $oauth->store_access_token_only(1, $test_client->loginid);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $params = {
    language => 'EN',
    token    => $token,
};

my @methods = qw(buy buy_contract_for_multiple_accounts sell cashier);

subtest 'no tnc yet' => sub {
    for my $method (@methods) {
        $c->call_ok($method, $params)->has_error->error_message_is('Terms and conditions approval is required.', "method $method check tnc");
    }
    done_testing();
};

$test_client->set_status('tnc_approval', 'system', 'test');
$test_client->save;

subtest 'tnc not correct yet' => sub {
    for my $method (@methods) {
        $c->call_ok($method, $params)->has_error->error_message_is('Terms and conditions approval is required.', "method $method check tnc");
    }
    done_testing();
};

done_testing();

