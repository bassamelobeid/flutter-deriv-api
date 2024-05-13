use strict;
use warnings;
use Test::Most;
use Test::Mojo;
use Test::Warnings;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::RPC::QueueClient;
use Test::MockModule;
use BOM::User;
use BOM::RPC::v3::Accounts;
use BOM::Database::Model::OAuth;
use utf8;
use Data::Dumper;
use Email::Stuffer::TestLinks;

my $email = 'dummy@binary.com';

my $test_client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});

$test_client_cr->set_default_account('USD');

$test_client_cr->email($email);
$test_client_cr->save;
my $user = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($test_client_cr);
my $oauth      = BOM::Database::Model::OAuth->new;
my $c          = BOM::Test::RPC::QueueClient->new();
my ($token_cr) = $oauth->store_access_token_only(1, $test_client_cr->loginid);
my @methods    = qw(buy_contract_for_multiple_accounts cashier);

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
done_testing();
