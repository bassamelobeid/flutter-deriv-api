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
use Test::MockModule;

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

$t = $t->send_ok({json => {proposal_open_contract => 1}})->message_ok;
my $empty_proposal_open_contract = decode_json($t->message->[1]);
ok $empty_proposal_open_contract->{proposal_open_contract} && !keys %{$empty_proposal_open_contract->{proposal_open_contract}};

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

my ($res, $contract_id);
## skip proposal until we meet buy
while (1) {
    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);
    note explain $res;
    next if $res->{msg_type} eq 'proposal';

    ok $res->{buy}->{contract_id};
    $contract_id = $res->{buy}->{contract_id};
    last;
}

$t = $t->send_ok({
        json => {
            proposal_open_contract => 1,
            subscribe              => 1
        }});

$t   = $t->message_ok;
$res = decode_json($t->message->[1]);
note explain $res;
is $res->{msg_type}, 'proposal_open_contract';
ok $res->{proposal_open_contract}->{contract_id};
SKIP: {
    skip 'SKIP until travis db connection will be fixed', 1 unless BOM::System::Config::env =~ /^qa/;
    ok $res->{proposal_open_contract}->{id};
}
test_schema('proposal_open_contract', $res);

is $res->{proposal_open_contract}->{contract_id}, $contract_id, 'got correct contract from proposal open contracts';

# It is hack to emulate contract selling and test subcribtion
my $rpc_caller = Test::MockModule->new('BOM::WebSocketAPI::CallingEngine');
my ($rpc_method, $call_params);

SKIP: {
    skip 'Skip failing tests on travis', 9 unless BOM::System::Config::env =~ /^qa/;
    $rpc_caller->mock(
        'call_rpc',
        sub {
            my ($c, $params) = @_;
            my $rpc_response_cb;
            ($rpc_method, $rpc_response_cb, $call_params) = ($params->{method}, $params->{rpc_response_cb}, $params->{call_params});
            $c->send({json => $rpc_response_cb->({ok => 1})});
        });

    my $msg = {
        action_type             => 'sell',
        account_id              => 201079,
        financial_market_bet_id => $contract_id,
        amount                  => 2500
    };
    my $json = JSON::to_json($msg);

    BOM::System::RedisReplicated::redis_write()->publish('TXNUPDATE::transaction_' . $msg->{account_id}, $json);

    $t   = $t->message_ok;
    $res = decode_json($t->message->[1]);

    is $res->{msg_type}, 'proposal_open_contract', 'Got message about selling contract';
    ok $res->{proposal_open_contract}->{sell_time},  'Got message about selling contract';
    ok $res->{proposal_open_contract}->{sell_price}, 'Got message about selling contract';
    is $res->{proposal_open_contract}->{ok},         1, 'Got message about selling contract';

    is $call_params->{contract_id}, $contract_id, 'Request RPC to sell contract';
    ok $call_params->{short_code},  'Request RPC to sell contract';
    ok $call_params->{sell_time},   'Request RPC to sell contract';

    is $rpc_method, 'get_bid';

    $rpc_caller->unmock_all;
}

$t = $t->send_ok({json => {forget_all => 'proposal_open_contract'}})->message_ok;

$rpc_caller->mock('call_rpc', sub { $call_params = $_[1]->{call_params}, shift->send({json => {ok => 1}}) });
$t = $t->send_ok({
        json => {
            proposal_open_contract => 1,
            contract_id            => 1
        }})->message_ok;
is $call_params->{token},       $token;
is $call_params->{args}->{contract_id}, 1;
$rpc_caller->unmock_all;

$t->finish_ok;

done_testing();
