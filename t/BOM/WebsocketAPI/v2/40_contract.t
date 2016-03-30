use Test::Most;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;

use BOM::Platform::SessionCookie;

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
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'sy@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR2002';

$t = $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
my $tick = decode_json($t->message->[1]);
ok $tick->{tick}->{id};
ok $tick->{tick}->{quote};
ok $tick->{tick}->{epoch};
test_schema('tick', $tick);

# stop tick
$t = $t->send_ok({json => {forget => $tick->{tick}->{id}}})->message_ok;
my $forget = decode_json($t->message->[1]);
ok $forget->{forget};
test_schema('forget', $forget);

$t = $t->send_ok({
        json => {
            "proposal"      => 1,
            "amount"        => "10",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "symbol"        => "R_50",
            "duration"      => "2",
            "duration_unit" => "m"
        }})->message_ok;
my $proposal = decode_json($t->message->[1]);
ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};
test_schema('proposal', $proposal);

sleep 1;
$t = $t->send_ok({
        json => {
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}}});

## skip proposal until we meet buy
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    next if $res->{msg_type} eq 'proposal';

    ok $res->{buy};
    ok $res->{buy}->{fmb_id};
    ok $res->{buy}->{purchase_time};

    test_schema('buy', $res);
    last;
}

$t = $t->send_ok({json => {forget => $proposal->{proposal}->{id}}})->message_ok;
$forget = decode_json($t->message->[1]);
ok $forget->{forget};

$t = $t->send_ok({json => {portfolio => 1}})->message_ok;
my $portfolio = decode_json($t->message->[1]);
ok $portfolio->{portfolio}->{contracts};
ok $portfolio->{portfolio}->{contracts}->[0]->{fmb_id};
test_schema('portfolio', $portfolio);

## test portfolio and sell
$t = $t->send_ok({
        json => {
            proposal_open_contract => 1,
            fmb_id                 => $portfolio->{portfolio}->{contracts}->[0]->{fmb_id},
        }});
$t = $t->message_ok;
my $res = decode_json($t->message->[1]);

if (exists $res->{proposal_open_contract}) {
    ok $res->{proposal_open_contract}->{id};
    test_schema('proposal_open_contract', $res);
}
$t->finish_ok;

done_testing();
