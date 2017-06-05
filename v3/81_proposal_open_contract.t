use strict;
use warnings;
use Test::More;
use Test::Deep;
use JSON;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client build_mojo_test wsapi_wait_for/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Platform::RedisReplicated;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Platform::Runtime;

build_test_R_50_data();
my $t = build_wsapi_test();

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

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->set_status('tnc_approval', 'system', BOM::Platform::Runtime->instance->app_config->cgi->terms_conditions_version);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::Platform::User->create(
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

subtest 'empty POC response' => sub {
    wsapi_wait_for(
        $t, 'proposal_open_contract',
        sub { $t->send_ok({json => {proposal_open_contract => 1}})->message_ok; },
        sub { note explain $_[0]; ok($_[0]->{proposal_open_contract} && !keys %{$_[0]->{proposal_open_contract}}, "got proposal"); }
    );
};
my ( $contract_id, $proposal );


subtest 'buy n check' => sub {
    wsapi_wait_for(
        $t, 'proposal',
        sub {
            $t->send_ok({
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

            BOM::Platform::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');
            $t->message_ok;
        },
        sub { $proposal = shift; },
    );

    wsapi_wait_for(
        $t, 'buy',
        sub {
            $t->send_ok({
                json => {
                    buy   => $proposal->{proposal}->{id},
                    price => $proposal->{proposal}->{ask_price}}});
            $t->message_ok;
        },
        sub { ok($contract_id = shift->{buy}->{contract_id}, "got contract_id"); }
    );

    wsapi_wait_for(
        $t, 'proposal_open_contract',
        sub {
            $t = $t->send_ok({
                json => {
                    proposal_open_contract => 1,
                    subscribe              => 1
                }})->message_ok;
        },
        sub {
            my $res = shift;
            is $res->{msg_type}, 'proposal_open_contract';
            ok $res->{echo_req};
            ok $res->{proposal_open_contract}->{contract_id};
            ok $res->{proposal_open_contract}->{id};
            test_schema('proposal_open_contract', $res);

            is $res->{proposal_open_contract}->{contract_id}, $contract_id, 'got correct contract from proposal open contracts';
        });
};

subtest 'passthrough' => sub {
    wsapi_wait_for(
        $t, 'proposal_open_contract',
        sub {
            $t->send_ok({
                json => {
                    proposal_open_contract => 1,
                    subscribe              => 1,
                    req_id                 => 456,
                    passthrough            => {'sample' => 1},
                }})->message_ok;
        },
        sub {
            is( shift->{proposal_open_contract}->{id}, undef, 'passthrough should not allow multiple proposal_open_contract subscription' );
        },
    );
};

subtest 'selling contract message' => sub {
    # It is hack to emulate contract selling and test subcribtion
    my ($url, $call_params);

    my $fake_res = Test::MockObject->new();
    $fake_res->mock('result', sub { +{ok => 1} });
    $fake_res->mock('is_error', sub { '' });

    my $fake_rpc_client = Test::MockObject->new();
    $fake_rpc_client->mock('call', sub { shift; $url = $_[0]; $call_params = $_[1]->{params}; return $_[2]->($fake_res) });

    my $module = Test::MockModule->new('MojoX::JSON::RPC::Client');
    $module->mock('new', sub { return $fake_rpc_client });

    my $mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        broker_code => $client->broker_code,
        operation   => 'replica'
    });
    my $contract_details = $mapper->get_contract_details_with_transaction_ids($contract_id);

    my $msg = {
        action_type             => 'sell',
        account_id              => $contract_details->[0]->{account_id},
        financial_market_bet_id => $contract_id,
        amount                  => 2500,
        short_code              => $contract_details->[0]->{short_code},
        currency_code           => 'USD',
    };

    wsapi_wait_for(
        $t, 'proposal_open_contract',
        sub {
            my $json = JSON::to_json($msg);
            BOM::Platform::RedisReplicated::redis_write()->publish('TXNUPDATE::transaction_' . $msg->{account_id}, $json);
            $t = $t->message_ok;
        },
        sub {
            is shift->{msg_type}, 'proposal_open_contract', 'Got message about selling contract';
        },
    );

    $module->unmock_all;
};

subtest 'forget' => sub {
    wsapi_wait_for(
        $t,
        'forget_all',
        sub {
            $t = $t->send_ok({json => {forget_all => 'proposal_open_contract'}})->message_ok;
        },
        sub {
            is(scalar @{shift->{forget_all}}, 0, 'Forget all returns empty as contracts are already sold');
        });
    my (undef,  $call_params) = call_mocked_client(
        $t,
        {
            proposal_open_contract => 1,
            contract_id            => 1
        });
    is $call_params->{token}, $token;
    is $call_params->{args}->{contract_id}, 1;
};

subtest 'check two contracts subscription' => sub {
    wsapi_wait_for(
        $t, 'proposal',
        sub {
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
            BOM::Platform::RedisReplicated::redis_write->publish('FEED::R_50', 'R_50;1447998048;443.6823;');
            $t->message_ok;
        },
        sub {
            $proposal = shift;
        });

    my $ids = {};

    wsapi_wait_for(
        $t, 'proposal_open_contract',
        sub {
            $t->send_ok({
                json => {
                    proposal_open_contract => 1,
                    subscribe              => 1
                }})->message_ok;
            $t->send_ok({
                json => {
                    buy   => $proposal->{proposal}->{id},
                    price => $proposal->{proposal}->{ask_price}}})->message_ok;

        }, sub { $ids->{shift->{proposal_open_contract}->{id}} = 1; }
    );

    my $i = 0;
    wsapi_wait_for(
        $t, 'proposal_open_contract',
        sub { $t->message_ok },
        sub { $ids->{shift->{proposal_open_contract}->{id}} = 1; }
    ) while ( scalar keys %$ids < 2 ) && ( ++$i < 5 );

    wsapi_wait_for(
        $t, 'forget_all',
        sub { $t->send_ok({json => {forget_all => 'proposal_open_contract'}})->message_ok; },
        sub {
            is scalar keys %$ids, 2, 'Correct number of contracts';
            ok( delete $ids->{shift @{$_[0]->{forget_all}}}, "check id") for 0..1;
            is scalar @{$_[0]->{forget_all}}, 0, 'Correct number of subscription forget';
        }
    );
};

$t->finish_ok;

done_testing();
