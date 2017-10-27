use strict;
use warnings;
use Test::More;
use Test::Deep;
use JSON::MaybeXS;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client build_mojo_test/;
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
my $json = JSON::MaybeXS->new;

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

$t->await::authorize({authorize => $token});
my $account_id =  $client->default_account->id;

subtest 'empty POC response' => sub {
    my $data = $t->await::proposal_open_contract({proposal_open_contract => 1});
    ok($data->{proposal_open_contract} && !keys %{$data->{proposal_open_contract}}, "got proposal");
};

my $contract_id;

subtest 'buy n check' => sub {

    my $proposal = $t->await::proposal({
        "proposal"      => 1,
        "subscribe"     => 1,
        "amount"        => "2",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "2",
        "duration_unit" => "m"
    });

    my $data = $t->await::buy({
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}});

    diag explain $data unless ok($contract_id = $data->{buy}->{contract_id}, "got contract_id");

    $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1
    });

    is $data->{msg_type}, 'proposal_open_contract';
    ok $data->{echo_req};
    ok $data->{proposal_open_contract}->{contract_id};
    ok $data->{proposal_open_contract}->{id};
    test_schema('proposal_open_contract', $data);

    is $data->{proposal_open_contract}->{contract_id}, $contract_id, 'got correct contract from proposal open contracts';
};

subtest 'passthrough' => sub {
    my $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1,
        req_id                 => 456,
        passthrough            => {'sample' => 1},
    });
    is($data->{proposal_open_contract}->{id}, undef, 'passthrough should not allow multiple proposal_open_contract subscription');
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

    BOM::Platform::RedisReplicated::redis_write()->publish('TXNUPDATE::transaction_' . $msg->{account_id}, $json->encode($msg));

    my $data = $t->await::proposal_open_contract();
    is($data->{msg_type}, 'proposal_open_contract', 'Got message about selling contract');

    $module->unmock_all;
};

subtest 'forget' => sub {
    my $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});
    is(scalar @{$data->{forget_all}}, 0, 'Forget all returns empty as contracts are already sold');
};


subtest 'check two contracts subscription' => sub {
    my $proposal = $t->await::proposal({
        "proposal"      => 1,
        "subscribe"     => 1,
        "amount"        => "2",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "2",
        "duration_unit" => "m"
    });

    my $ids = {};

    my $res = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1
    });

    my $buy_res = $t->await::buy({
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}});

    ok($contract_id = $buy_res->{buy}->{contract_id}, "got contract_id");

    my $msg = {
        %$buy_res,
        action_type             => 'buy',
        account_id              => $account_id,
        financial_market_bet_id => $buy_res->{buy}{contract_id},
        amount                  => $buy_res->{buy}{buy_price},
        short_code              => $buy_res->{buy}{shortcode},
        currency_code           => 'USD',

    };

    BOM::Platform::RedisReplicated::redis_write()->publish('TXNUPDATE::transaction_' . $msg->{account_id}, $json->encode($msg));

    sleep 2; ### we must wait for pricing rpc response

    my $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});

    diag explain $buy_res if not is(scalar @{$data->{forget_all}}, 2, 'Correct number of subscription forget');
};

subtest 'rpc error' => sub {


    my $proposal = $t->await::proposal({
        "proposal"      => 1,
        "subscribe"     => 1,
        "amount"        => "2",
        "basis"         => "payout",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "2",
        "duration_unit" => "m"
    });

    my $data = $t->await::buy({
            buy   => $proposal->{proposal}->{id},
            price => $proposal->{proposal}->{ask_price}});

    diag explain $data unless ok($contract_id = $data->{buy}->{contract_id}, "got contract_id");

    my ($fake_rpc_response, $fake_rpc_client, $rpc_client_mock);
    $fake_rpc_response = Test::MockObject->new();
    $fake_rpc_response->mock('is_error',      sub { 0 });
    $fake_rpc_response->mock('result',        sub { +{ error => {
                                                            code => 'InvalidToken',
                                                            message_to_client => 'The token is invalid.'
                                                }} });
    $fake_rpc_response->mock('error_message', sub { 'error' });
    $fake_rpc_client = Test::MockObject->new();
    $fake_rpc_client->mock('call', sub { shift; return $_[2]->($fake_rpc_response) });
    $rpc_client_mock = Test::MockModule->new('MojoX::JSON::RPC::Client');
    $rpc_client_mock->mock('new', sub { return $fake_rpc_client });


    $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1
    });
    cmp_ok $data->{error}{code}, 'eq', 'InvalidToken', "Got prope error message";

};

$t->finish_ok;

done_testing();
