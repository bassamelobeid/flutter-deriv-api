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

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::System::RedisReplicated;

build_test_R_50_data();
my $t = build_mojo_test();

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;

my $loginid = $client->loginid;
my $user = BOM::Platform::User->create(
    email    => $email,
    password => '1234',
);
$user->add_loginid({loginid => $loginid});
$user->save;

$client->set_default_account('USD');
$client->smart_payment(
    currency     => 'USD',
    amount       => +100,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

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
            subscribe              => 1,
            req_id                 => 123
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

$t = $t->send_ok({
        json => {
            proposal_open_contract => 1,
            subscribe              => 1,
            req_id                 => 456
        }});

$t   = $t->message_ok;
$res = decode_json($t->message->[1]);

is $res->{proposal_open_contract}->{id}, undef, 'different req_id should not allow multiple proposal_open_contract subscription';

$t = $t->send_ok({
        json => {
            proposal_open_contract => 1,
            subscribe              => 1,
            req_id                 => 123,
            passthrough            => 'sample'
        }});

$t   = $t->message_ok;
$res = decode_json($t->message->[1]);

is $res->{proposal_open_contract}->{id}, undef, 'passthrough should not allow multiple proposal_open_contract subscription';

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
is $call_params->{token}, $token;
is $call_params->{args}->{contract_id}, 1;
$rpc_caller->unmock_all;

$t->finish_ok;

done_testing();
