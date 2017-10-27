use strict;
use warnings;
use Test::More;
use JSON::MaybeXS;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);

my $t = build_wsapi_test();
my $json = JSON::MaybeXS->new;

# check for authenticated call
$t = $t->send_ok({json => {reality_check => 1}})->message_ok;
my $response = $json->decode($t->message->[1]);

is $response->{error}->{code},    'AuthorizationRequired';
is $response->{error}->{message}, 'Please log in.';

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, 'CR0021');

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $res = $json->decode($t->message->[1]);
is $res->{authorize}->{loginid}, 'CR0021';

$t = $t->send_ok({json => {reality_check => 1}})->message_ok;
$res = $json->decode($t->message->[1]);
test_schema('reality_check', $res);

done_testing();

