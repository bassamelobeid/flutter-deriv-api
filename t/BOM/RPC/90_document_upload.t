use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use utf8;
use Data::Dumper;

my $email       = 'dummy@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
});
$test_client->email($email);
$test_client->save;

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'document_upload';
my $params = {
    language => 'EN',
    token    => 12345
};

# Invalid token shouldn't be allowed to upload.
$c->call_ok($method, $params)->has_error->error_message_is('The token is invalid.', 'check invalid token');

$params->{token} = $token;
# Valid token but virtual account.
$c->call_ok($method, $params)->has_error->error_message_is("Virtual accounts don't require uploads.", "don't allow virtual accounts to upload");

# Creating new real account.
$test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

# For CR accounts.
$params->{token} = $token;
$params->{upload_id} = "some_id";
my $result = $c->call_ok($method, $params)->result;

print Dumper($result);

done_testing();
