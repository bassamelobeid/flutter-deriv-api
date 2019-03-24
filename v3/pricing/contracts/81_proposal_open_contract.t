use strict;
use warnings;
use Test::More;
use Test::Deep;
use Encode;
use JSON::MaybeXS;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client build_mojo_test/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;
use Test::MockObject;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Config::RedisReplicated;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Config::Runtime;

build_test_R_50_data();
my $t    = build_wsapi_test();
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
$client->status->set('tnc_approval', 'system', BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($client);

$client->set_default_account('USD');
$client->smart_payment(
    currency     => 'USD',
    amount       => +100,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
my $account_id = $client->default_account->id;

subtest 'Authorization' => sub {
    my $data = $t->await::proposal_open_contract({proposal_open_contract => 1});
    ok $data->{error}, 'There is an error';
    is $data->{error}->{code},    'AuthorizationRequired';
    is $data->{error}->{message}, 'Please log in.';

    $t->await::authorize({authorize => $token});

    $data = $t->await::proposal_open_contract({proposal_open_contract => 1});
    ok($data->{proposal_open_contract} && !keys %{$data->{proposal_open_contract}}, "got proposal");
    ok !$data->{error}, 'No error';
    test_schema('proposal_open_contract', $data);
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
        price => $proposal->{proposal}->{ask_price},
    });

    diag explain $data unless ok($contract_id = $data->{buy}->{contract_id}, "got contract_id");

    #call without subscription
    $data = $t->await::proposal_open_contract({proposal_open_contract => 1});
    is $data->{msg_type}, 'proposal_open_contract';
    is $data->{proposal_open_contract}->{id}, undef, 'No id for non-subscribed calls';
    is $data->{subscription}, undef, 'There is not a subscription key';
    ok $data->{proposal_open_contract}->{contract_id}, 'There is a contract id';
    is $data->{proposal_open_contract}->{contract_id}, $contract_id, 'Contract id is the same as the value returned by <buy>';
    test_schema('proposal_open_contract', $data);

    #call withoiut subscription
    $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1
    });
    is $data->{msg_type}, 'proposal_open_contract';
    ok $data->{echo_req};
    ok $data->{proposal_open_contract}->{contract_id};
    ok $data->{proposal_open_contract}->{id},          'There is an id';
    is $data->{subscription}->{id},                    $data->{proposal_open_contract}->{id}, 'The same subscription id';
    is $data->{proposal_open_contract}->{contract_id}, $contract_id, 'got correct contract from proposal open contracts';
    test_schema('proposal_open_contract', $data);
};

subtest 'passthrough' => sub {
    my $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1,
        req_id                 => 456,
        passthrough            => {'sample' => 1},
    });

    is($data->{proposal_open_contract}->{id}, undef, 'passthrough should not allow multiple proposal_open_contract subscription');
    is($data->{subscription},                 undef, 'No subscription key either');
    ok $data->{error}, 'Has an error';
    is $data->{error}->{code}, 'AlreadySubscribed', 'Correct error message';
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

    BOM::Config::RedisReplicated::redis_write()->publish('TXNUPDATE::transaction_' . $msg->{account_id}, Encode::encode_utf8($json->encode($msg)));

    my $data = $t->await::proposal_open_contract();
    is($data->{msg_type}, 'proposal_open_contract', 'Got message about selling contract');
    is $data->{proposal_open_contract}->{contract_id}, $contract_id, 'Contract id is correct';

    $module->unmock_all;
};

subtest 'forget' => sub {
    my $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});
    is(scalar @{$data->{forget_all}}, 0, 'Forget all returns empty as contracts are already sold');

    my $proposal = {
        "amount"        => "2",
        "basis"         => "stake",
        "contract_type" => "CALL",
        "currency"      => "USD",
        "symbol"        => "R_50",
        "duration"      => "2",
        "duration_unit" => "m"
    };

    $data = $t->await::buy({
        buy        => 1,
        parameters => {%$proposal},
        price      => 2
    });
    is $data->{error}, undef, 'No error';
    ok $contract_id = $data->{buy}->{contract_id}, "got contract_id";

    #subscription by poc call
    $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        contract_id            => $contract_id,
        subscribe              => 1,
    });
    ok !$data->{error}, 'No error';
    is $data->{proposal_open_contract}->{contract_id}, $contract_id, 'The same contract id';
    ok my $uuid1 = $data->{subscription}->{id}, 'Subscription id 1';

    #subscription by <buy> call
    $data = $t->await::buy({
        buy        => 1,
        parameters => {%$proposal},
        price      => 2,
        subscribe  => 1
    });
    ok !$data->{error}, 'No error';
    ok $data->{buy}->{contract_id}, 'got contract id';
    ok my $uuid2 = $data->{subscription}->{id}, 'Subscription id 2';

    $data = $t->await::forget({forget => $uuid1});
    ok !$data->{error}, 'No error';
    is $data->{forget}, 1, 'Subscription 1 is forgotten here';

    $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});
    is scalar @{$data->{forget_all}}, 1, 'One subscription left';
    is $data->{forget_all}->[0], $uuid2, 'Subscription 2 is forgotten here';
};

subtest 'check two contracts subscription' => sub {
    my $data = $t->await::portfolio({portfolio => 1});
    ok my $init_open_contracts_count = @{$data->{portfolio}->{contracts}}, 'The number of open contracts';

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

    $data = $t->await::portfolio({portfolio => 1});
    is @{$data->{portfolio}->{contracts}}, $init_open_contracts_count + 1, 'The contract is added to portfolio';

    my $msg = {
        %$buy_res,
        action_type             => 'buy',
        account_id              => $account_id,
        financial_market_bet_id => $buy_res->{buy}{contract_id},
        amount                  => $buy_res->{buy}{buy_price},
        short_code              => $buy_res->{buy}{shortcode},
        currency_code           => 'USD',

    };

    BOM::Config::RedisReplicated::redis_write()->publish('TXNUPDATE::transaction_' . $msg->{account_id}, Encode::encode_utf8($json->encode($msg)));

    $data = $t->await::portfolio({portfolio => 1});
    is @{$data->{portfolio}->{contracts}}, $init_open_contracts_count + 1, 'Duplicate transaction feed does not change the portfolio';

    $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});
    is(
        scalar @{$data->{forget_all}},
        $init_open_contracts_count + 2,
        'But new proposal_open_contract subscription is created by the redundant transaction feed'
    );
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
    $fake_rpc_response->mock('is_error', sub { 0 });
    $fake_rpc_response->mock(
        'result',
        sub {
            +{
                error => {
                    code              => 'InvalidToken',
                    message_to_client => 'The token is invalid.'
                }};
        });
    $fake_rpc_response->mock('error_message', sub { 'error' });
    $rpc_client_mock = Test::MockModule->new('MojoX::JSON::RPC::Client');
    $rpc_client_mock->mock('call', sub { shift; return $_[2]->($fake_rpc_response) });

    $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1
    });
    cmp_ok $data->{error}{code}, 'eq', 'InvalidToken', "Got prope error message";

};

$t->finish_ok;

done_testing();
