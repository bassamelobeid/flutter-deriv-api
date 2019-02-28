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
use Email::Stuffer::TestLinks;

my $email = 'dummy@binary.com';

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
});

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

$test_client->email($email);
$test_client->save;
$test_client_cr->email($email);
$test_client_cr->save;
my $user = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($test_client);
$user->add_client($test_client_cr);

my $oauth = BOM::Database::Model::OAuth->new;
my ($token)    = $oauth->store_access_token_only(1, $test_client->loginid);
my ($token_cr) = $oauth->store_access_token_only(1, $test_client_cr->loginid);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my @methods = qw(buy buy_contract_for_multiple_accounts sell cashier);

my $params = {
    language => 'EN',
    token    => $token_cr,
};

# Since we're caling these methods without proper parameters warnings may be generated if the tnc check passes
Test::Warnings::allow_warnings(1);
subtest 'tnc exempt' => sub {
    for my $method (@methods) {
        my $result = $c->call_ok($method, $params);
        isnt($result->{error}->{message_to_client}, 'Terms and conditions approval is required.', "method $method check tnc exempt");
    }
};
Test::Warnings::allow_warnings(0);

$params = {
    language => 'EN',
    token    => $token,
};

subtest 'no tnc yet' => sub {
    for my $method (@methods) {
        $c->call_ok($method, $params)->has_error->error_message_is('Terms and conditions approval is required.', "method $method check tnc");
    }
    done_testing();
};

$test_client->status->set('tnc_approval', 'system', 'test');

subtest 'tnc not correct yet' => sub {
    for my $method (@methods) {
        $c->call_ok($method, $params)->has_error->error_message_is('Terms and conditions approval is required.', "method $method check tnc");
    }
    done_testing();
};

done_testing();

