use strict;
use warnings;

use Test::Most;
use Test::MockTime qw/:all/;
use Encode;
use JSON::MaybeXS;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data/;
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::AccessToken;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

build_test_R_50_data();

my $t     = build_wsapi_test();
my $token = BOM::Database::Model::AccessToken->new->create_token("CR2002", 'Test', ['price', 'trade']);
my $json  = JSON::MaybeXS->new;
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

my ($req, $res, $start, $end);
$req = {
    "proposal"      => 1,
    "subscribe"     => 1,
    "amount"        => 640,
    "basis"         => "payout",
    "contract_type" => "CALL",
    "currency"      => "USD",
    "symbol"        => "R_50",
    "duration"      => 5,
    "duration_unit" => "t",
};

$t->send_ok({json => $req})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
my $uuid = $res->{proposal}->{id};
ok $uuid, 'Should return id';
is $res->{subscription}->{id}, $uuid, 'Subscription id with a correct value';

$t->send_ok({json => $req})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is $res->{error}->{code}, 'AlreadySubscribed', 'Correct error for already subscribed with same req_id';

$t->send_ok({json => {forget_all => 'proposal'}})->message_ok;
$res = $json->decode(Encode::decode_utf8($t->message->[1]));
is scalar @{$res->{forget_all}}, 1, 'Correct number of subscriptions forgotten';
is $res->{forget_all}->[0], $uuid, 'Correct subscription id forgotten';

done_testing();
