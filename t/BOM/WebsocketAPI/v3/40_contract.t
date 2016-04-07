#!perl

use Test::Most;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test build_test_R_50_data/;
use Net::EmptyPort qw(empty_port);

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
my $authorize = decode_json($t->message->[1]);
is $authorize->{authorize}->{email},   'sy@regentmarkets.com';
is $authorize->{authorize}->{loginid}, 'CR2002';

my %contractParameters = (
    "amount"        => "10",
    "basis"         => "payout",
    "contract_type" => "CALL",
    "currency"      => "USD",
    "symbol"        => "R_50",
    "duration"      => "2",
    "duration_unit" => "m",
);
$t = $t->send_ok({
        json => {
            "proposal"  => 1,
            "subscribe" => 1,
            %contractParameters
        }});
BOM::System::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');
$t->message_ok;
my $proposal = decode_json($t->message->[1]);
ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};
test_schema('proposal', $proposal);

sleep 1;
my $ask_price = $proposal->{proposal}->{ask_price};
$t = $t->send_ok({
        json => {
            buy   => $proposal->{proposal}->{id},
            price => $ask_price
        }});

## skip proposal until we meet buy
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    note explain $res;
    next if $res->{msg_type} eq 'proposal';

    ok $res->{buy};
    ok $res->{buy}->{contract_id};
    ok $res->{buy}->{purchase_time};

    test_schema('buy', $res);
    last;
}

$t = $t->send_ok({json => {forget => $proposal->{proposal}->{id}}})->message_ok;
my $forget = decode_json($t->message->[1]);
note explain $forget;
is $forget->{forget}, 0, 'buying a proposal deletes the stream';

$t = $t->send_ok({json => {portfolio => 1}})->message_ok;
my $portfolio = decode_json($t->message->[1]);
ok $portfolio->{portfolio}->{contracts};
ok $portfolio->{portfolio}->{contracts}->[0]->{contract_id};
test_schema('portfolio', $portfolio);

$t = $t->send_ok({
        json => {
            proposal_open_contract => 1,
            contract_id            => $portfolio->{portfolio}->{contracts}->[0]->{contract_id},
        }});
$t = $t->message_ok;
my $res = decode_json($t->message->[1]);

if (exists $res->{proposal_open_contract}) {
    ok $res->{proposal_open_contract}->{contract_id};
    test_schema('proposal_open_contract', $res);
}

sleep 5;
$t = $t->send_ok({
        json => {
            buy        => 1,
            price      => $ask_price,
            parameters => \%contractParameters,
        },
    });

## skip proposal until we meet buy
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    note explain $res;
    next if $res->{msg_type} eq 'proposal';

    note explain $res;
    ok $res->{buy};
    ok $res->{buy}->{contract_id};
    ok $res->{buy}->{purchase_time};

    test_schema('buy', $res);
    last;
}

$t->finish_ok;

done_testing();
