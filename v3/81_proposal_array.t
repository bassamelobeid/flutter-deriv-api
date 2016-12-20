use strict;
use warnings;
use Test::More;
use Test::Deep;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;
use Data::Dumper;
use Try::Tiny;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::System::RedisReplicated;
use BOM::Database::DataMapper::FinancialMarketBet;

build_test_R_50_data();
my $t = build_wsapi_test();
$t = $t->send_ok({json => {proposal_array => 1}})->message_ok;
my $empty_proposal_open_contract = decode_json($t->message->[1]);
is($empty_proposal_open_contract->{error}{details}{barriers}, 'is missing and it is required');

my $sent_json = {
    "proposal_array" => 1,
    "amount"         => "100",
    "basis"          => "payout",
    "currency"       => "USD",
    "contract_type"  => "CALL",
    "symbol"         => "R_100",
    "duration"       => "1",
    "duration_unit"  => "m",
    "barriers"       => [{"barrier" => "+1"}, {"barrier" => "+2"}]};

my @res;
try {
    local $SIG{ALRM} = sub { die "timeout" };
    alarm(3);
    $t = $t->send_ok({json => $sent_json});
    $t = $t->message_ok;
    push @res, decode_json($t->message->[1]);
    $t = $t->message_ok;
    push @res, decode_json($t->message->[1]);
    alarm(0);
}
catch {
    fail("time out");
};

is(scalar(@res), 2 , "2 responses");

@res = sort { $a->{echo_req}{barrier} cmp $b->{echo_req}{barrier} } @res;

for (0 .. 1) {
    is($res[$_]{echo_req}{barrier},  $sent_json->{barriers}[$_]{barrier}, 'barrier correct');
    is($res[$_]{echo_req}{proposal}, "1",                                 "ws command should be a proposal");
    is($res[$_]{msg_type},           'proposal',                          "message type should be proposal");
}

@res       = ();
$sent_json = {
    "proposal_array" => 1,
    "amount"         => "100",
    "basis"          => "payout",
    "currency"       => "USD",
    "contract_type"  => "EXPIRYMISS",
    "symbol"         => "R_100",
    "duration"       => "2",
    "duration_unit"  => "m",
    "barriers"       => [{
            "barrier"  => "+1",
            "barrier2" => "-1",
        },
        {
            "barrier"  => "+2",
            "barrier2" => "-2",
        }]};

try {
    local $SIG{ALRM} = sub { die "timeout" };
    alarm(3);
    $t = $t->send_ok({json => $sent_json});
    $t = $t->message_ok;
    push @res, decode_json($t->message->[1]);
    $t = $t->message_ok;
    push @res, decode_json($t->message->[1]);
    alarm(0);
}
catch {
    ok(0, "time out to wait messages");
  };

@res = sort { $a->{echo_req}{barrier} cmp $b->{echo_req}{barrier} } @res;

for (0 .. 1) {
    is($res[$_]{echo_req}{barrier},  $sent_json->{barriers}[$_]{barrier},  'barrier correct');
    is($res[$_]{echo_req}{barrier2}, $sent_json->{barriers}[$_]{barrier2}, 'barrier2 correct');
    is($res[$_]{echo_req}{proposal}, "1",                                  "ws command should be a proposal");
    is($res[$_]{msg_type},           'proposal',                           "message type should be proposal");
}

done_testing;
