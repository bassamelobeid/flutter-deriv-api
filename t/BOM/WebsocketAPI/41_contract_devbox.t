use Test::Most;
use Test::Mojo;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use JSON::Schema;
use File::Slurp;

use BOM::Platform::SessionCookie;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

plan skip_all => 'devbox only' if $ENV{TRAVIS};

my $config_dir = "$Bin/../../../config/v1";

my $t = Test::Mojo->new('BOM::WebSocketAPI');
$t->websocket_ok("/websockets/contracts");

my $token = BOM::Platform::SessionCookie->new(
    client_id       => 1,
    loginid         => "CR2002",
    email           => 'CR2002@binary.com',
    expiration_time => time() + 600,
    scopes          => ['price', 'trade'],
)->token;

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'CR2002@binary.com';
is $authorize->{authorize}->{loginid}, 'CR2002';

$t = $t->send_ok({json => {ticks => 'R_50'}})->message_ok;
my $tick = decode_json($t->message->[1]);
ok $tick->{tick}->{id};
ok $tick->{tick}->{quote};
ok $tick->{tick}->{epoch};

my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/tick/receive.json")));
my $result    = $validator->validate($tick);
ok $result, "tick response is valid";
# diag " - $_\n" foreach $result->errors;

# stop tick
$t = $t->send_ok({json => {forget => $tick->{tick}->{id}}})->message_ok;
my $forget = decode_json($t->message->[1]);
ok $forget->{forget};

$t = $t->send_ok({
        json => {
            "proposal"      => 1,
            "amount_val"    => "10",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "symbol"        => "R_50",
            "duration"      => "15",
            "duration_unit" => "s"
        }})->message_ok;
my $proposal = decode_json($t->message->[1]);
ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};

$validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/get_price/receive.json")));
$result    = $validator->validate($proposal);
ok $result, "get_price response is valid";
# diag " - $_\n" foreach $result->errors;

sleep 1;
$t = $t->send_ok({
        json => {
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}}});

## skip proposal until we meet open_receipt
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    next if $res->{msg_type} eq 'proposal';

    ok $res->{open_receipt};
    ok $res->{open_receipt}->{fmb_id};
    ok $res->{open_receipt}->{purchase_time};

    $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/buy/receive.json")));
    $result    = $validator->validate($res);
    ok $result, "buy response is valid";
    # diag " - $_\n" foreach $result->errors;

    last;
}

$t = $t->send_ok({json => {forget => $proposal->{proposal}->{id}}})->message_ok;
$forget = decode_json($t->message->[1]);
ok $forget->{forget};

## test portfolio and sell
$t = $t->send_ok({json => {portfolio => 1}});
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    diag Dumper(\$res);

    if (exists $res->{portfolio}) {
        ok $res->{portfolio}->{id};
        ok $res->{portfolio}->{ask_price};

        $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/portfolio/receive.json")));
        $result    = $validator->validate($res);
        ok $result, "portfolio response is valid";
        # diag " - $_\n" foreach $result->errors;

        ## try sell
        $t = $t->send_ok({
                json => {
                    sell  => $res->{portfolio}->{id},
                    price => $res->{portfolio}->{ask_price}}});

    } elsif (exists $res->{portfolio_stats}) {
        ok(defined $res->{portfolio_stats}->{number_of_sold_bets});
        ok($res->{portfolio_stats}->{batch_count});
    } else {
        ok $res->{close_receipt};

        ## FIXME
        ## not OK to sell: Contract must be held for 1 minute before resale is offered.

        # $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("$config_dir/sell/receive.json")));
        # $result    = $validator->validate($res);
        # ok $result, "sell response is valid";
        # # diag " - $_\n" foreach $result->errors;

        last;
    }
}

$t->finish_ok;

done_testing();
