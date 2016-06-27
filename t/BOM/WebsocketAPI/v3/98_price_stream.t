use strict;
use warnings;

use Test::Most;
use Test::MockTime qw/:all/;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;

my ($req, $res, $start, $end);

build_test_R_50_data();

my $t     = build_mojo_test();
my $token = BOM::Database::Model::AccessToken->new->create_token("CR2002", 'Test', ['price', 'trade']);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;

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
$res = decode_json($t->message->[1]);
ok $res->{proposal}->{id}, 'Should return id';

done_testing();
