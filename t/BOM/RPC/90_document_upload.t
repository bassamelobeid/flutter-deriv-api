use strict;
use warnings;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use utf8;

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
$c->call_ok($method, $params)
    ->has_error->error_message_is("Virtual accounts don't require document uploads.", "don't allow virtual accounts to upload");

# Creating new real account.
$test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

# For CR accounts.
$params->{token}  = $token;
$params->{upload} = "some_id";

$params->{expiration_date} = "asdaas-asd-asd";    # Invalid date
$c->call_ok($method, $params)->has_error->error_message_is('Invalid expiration_date.', 'check invalid expiration_date');

$params->{expiration_date} = "2017-08-09";        # Expired documents.
$c->call_ok($method, $params)
    ->has_error->error_message_is('expiration_date cannot be less than or equal to current date.', 'check expiration_date is before current date');

# Missing parameters
$params->{expiration_date} = "2117-08-11";        # 100 years is all I give you, humanity!
$c->call_ok($method, $params)->has_error->error_message_is('Missing parameter.', 'check if missing parameters');

$params->{document_type}   = "passport";
$params->{document_id}     = "ABCD1234";
$params->{document_format} = "jpg";
my $result = $c->call_ok($method, $params)->result;
my @docs = $test_client->find_client_authentication_document(query => [document_path => $result->{file_name}]);
# Succesfully retrieved object from database.
is($docs[0]->document_id, $params->{document_id});

done_testing();
