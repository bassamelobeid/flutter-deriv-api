use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;
use Net::EmptyPort qw(empty_port);

use BOM::Test;
use BOM::Platform::SessionCookie;
use BOM::System::RedisReplicated;

build_test_R_50_data();
my $t = build_mojo_test();

my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'sy@regentmarkets.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;

$t = $t->send_ok({
        json => {
            "proposal"      => 1,
            "subscribe"     => 1,
            "amount"        => "2",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "symbol"        => "R_50",
            "duration"      => "2",
            "duration_unit" => "m"
        }});
BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');
$t->message_ok;
my $proposal = decode_json($t->message->[1]);

sleep 1;
$t = $t->send_ok({
        json => {
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}}});

my ($res, $first_contract_id);
## skip proposal until we meet buy
while (1) {
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    note explain $res;
    next if $res->{msg_type} eq 'proposal';

    ok $res->{buy}->{contract_id};
    $first_contract_id = $res->{buy}->{contract_id};
    last;
}

$t = $t->send_ok({
        json => {
            "proposal"      => 1,
            "subscribe"     => 1,
            "amount"        => "2",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "symbol"        => "R_50",
            "duration"      => "2",
            "duration_unit" => "m"
        }});
BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998050;445.6823;');
$t->message_ok;
$proposal = decode_json($t->message->[1]);

sleep 1;
$t = $t->send_ok({
        json => {
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}}});

my $second_contract_id;
## skip proposal until we meet buy
while (1) {
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    note explain $res;
    next if $res->{msg_type} eq 'proposal';

    ok $res->{buy}->{contract_id};
    $second_contract_id = $res->{buy}->{contract_id};
    last;
}

$t = $t->send_ok({
        json => {
            proposal_open_contract => 1,
            subscribe              => 1
        }});

my $contract_count = 0;
for (my $i = 0; $i < 4; $i++) {
    last if ($contract_count == 2);
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    note explain $res;
    ok $res->{proposal_open_contract}->{contract_id};
    test_schema('proposal_open_contract', $res);
    if ($first_contract_id eq $res->{proposal_open_contract}->{contract_id} or $second_contract_id eq $res->{proposal_open_contract}->{contract_id}) {
        $contract_count++;
    }
}

is $contract_count, 2, 'got correct number of proposal open contracts';

$t = $t->send_ok({json => {forget_all => 'proposal_open_contract'}})->message_ok;
$t->finish_ok;

done_testing();
