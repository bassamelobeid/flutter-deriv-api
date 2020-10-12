use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;
use Test::MockModule;

use BOM::User;
use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

use await;

my $t = build_wsapi_test();

# check for authenticated call
my $response = $t->await::sell_expired({sell_expired => 1});

is $response->{error}->{code},    'AuthorizationRequired';
is $response->{error}->{message}, 'Please log in.';

my $email       = 'unit_test@binary.com';
my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
});
$test_client->email($email);
$test_client->save;

my $loginid = $test_client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($test_client);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $test_client->loginid);

my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   'unit_test@binary.com';
is $authorize->{authorize}->{loginid}, $test_client->loginid;

# wrong call
$response = $t->await::sell_expired({sell_expired => 2});

is $response->{error}->{code}, 'InputValidationFailed';

my $call_params;
($response, $call_params) = call_mocked_consumer_groups_request(
    $t,
    {
        sell_expired => 1,
        req_id       => 123,
    });
is $call_params->{token}, $token;
is $response->{msg_type}, 'sell_expired';
is $response->{echo_req}->{sell_expired}, 1;
is $response->{echo_req}->{req_id},       123;
is $response->{req_id}, 123;

done_testing();
