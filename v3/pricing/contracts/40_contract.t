#!perl

use strict;
use warnings;

use Test::Most;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase;
use Date::Utility;
use await;

use JSON::MaybeXS;

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
    amount       => +10000,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

my $authorize = $t->await::authorize({authorize => $token});
is $authorize->{authorize}->{email},   $email;
is $authorize->{authorize}->{loginid}, $loginid;

my %contractParameters = (
    "amount"        => "5",
    "basis"         => "payout",
    "contract_type" => "CALL",
    "currency"      => "USD",
    "symbol"        => "R_50",
    "duration"      => "2",
    "duration_unit" => "m",
);

my $proposal = $t->await::proposal({
    proposal => 1,
    %contractParameters
});
ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};
test_schema('proposal', $proposal);

my $id1 = $proposal->{proposal}->{id};
$proposal = $t->await::proposal({
    proposal => 1,
    %contractParameters
});
ok $proposal->{proposal}->{id};
cmp_ok $id1, 'eq', $proposal->{proposal}->{id}, 'ids are the same for same parameters';

$contractParameters{amount}++;
$proposal = $t->await::proposal({
    proposal => 1,
    %contractParameters
});
ok $proposal->{proposal}->{id};
cmp_ok $id1, 'ne', $proposal->{proposal}->{id}, 'ids are not the same if parameters are different';
$contractParameters{amount}--;

$proposal = $t->await::proposal({
    proposal  => 1,
    subscribe => 1,
    %contractParameters
});

ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};
test_schema('proposal', $proposal);

my $err_proposal = $t->await::proposal({
    proposal  => 1,
    subscribe => 1,
    %contractParameters
});

cmp_ok $err_proposal->{msg_type},, 'eq', 'proposal';
cmp_ok $err_proposal->{error}->{code},, 'eq', 'AlreadySubscribed', 'AlreadySubscribed error expected';

sleep 1;
my $buy_error = $t->await::buy({
    buy   => 1,
    price => 1
});
is $buy_error->{msg_type}, 'buy';
is $buy_error->{error}->{code}, 'InvalidContractProposal';

my $ask_price = $proposal->{proposal}->{ask_price};
my $buy_res   = $t->await::buy({
    buy   => $proposal->{proposal}->{id},
    price => $ask_price || 0
});

next if $buy_res->{msg_type} eq 'proposal';

ok $buy_res->{buy};
ok $buy_res->{buy}->{contract_id};
ok $buy_res->{buy}->{purchase_time};

test_schema('buy', $buy_res);

my $forget = $t->await::forget({forget => $proposal->{proposal}->{id}});

is $forget->{forget}, 0, 'buying a proposal deletes the stream';

my (undef, $call_params) = call_mocked_client($t, {portfolio => 1});
is $call_params->{token}, $token;

my $portfolio = $t->await::portfolio({portfolio => 1});
is $portfolio->{msg_type}, 'portfolio';
ok $portfolio->{portfolio}->{contracts};
ok $portfolio->{portfolio}->{contracts}->[0]->{contract_id};
test_schema('portfolio', $portfolio);

# proposal_open_contract is tested in 81_proposal_open_contract.t
my $res;

(undef, $call_params) = call_mocked_client(
    $t,
    {
        buy        => 1,
        price      => $ask_price || 0,
        parameters => \%contractParameters,
    });
is $call_params->{token}, $token;
ok $call_params->{contract_parameters};

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'R_50',
    epoch      => Date::Utility->new->epoch + 2,
    quote      => '963'
});

$res = $t->await::buy({
    buy        => 1,
    price      => $ask_price || 0,
    parameters => \%contractParameters,
});

my $buy_txn_id = 0;
my $contract_id;
## skip proposal until we meet buy
is $res->{msg_type}, 'buy';
ok $res->{buy};
ok($contract_id = $res->{buy}->{contract_id});
ok($buy_txn_id  = $res->{buy}->{transaction_id});
ok $res->{buy}->{purchase_time};

test_schema('buy', $res);

(undef, $call_params) = call_mocked_client(
    $t,
    {
        sell  => 1,
        price => $ask_price || 0,
    });
is $call_params->{token}, $token;
sleep 1;
$res = $t->await::sell({
    sell  => $contract_id,
    price => 0
});
ok $res->{sell};
ok($res->{sell}{contract_id} && $res->{sell}{contract_id} == $contract_id, "check contract ID");
ok($res->{sell}{reference_id} == $buy_txn_id, "check buy transaction ID");
test_schema('sell', $res);

sleep 1;
my %notouch = (
    "amount"        => "100",
    "basis"         => "payout",
    "contract_type" => "NOTOUCH",
    "currency"      => "USD",
    "symbol"        => "R_50",
    "duration"      => "2",
    "duration_unit" => "h",
    "barrier"       => "+1.574"
);

my $proposal_1 = $t->await::proposal({
    proposal => 1,
    %notouch
});
my $proposal_id        = $proposal_1->{proposal}->{id};
my $proposal_ask_price = $proposal_1->{proposal}->{ask_price};
my $trigger_price      = $proposal_ask_price - 2;
my $response           = $t->await::buy({
    buy   => $proposal_id,
    price => $trigger_price
});

like(
    $response->{error}{message},
    qr/The underlying market has moved too much since you priced the contract. The contract price has changed/,
    'price moved error'
);

$t->await::forget({forget => $proposal_1->{proposal}->{id}});

my %notouch_2 = (
    "amount"        => "1",
    "basis"         => "stake",
    "contract_type" => "NOTOUCH",
    "currency"      => "USD",
    "symbol"        => "R_100",
    "duration"      => "2",
    "duration_unit" => "m",
    "barrier"       => "+25"
);

$proposal_1 = $t->await::proposal({
    proposal => 1,
    %notouch_2
});
$proposal_id = $proposal_1->{proposal}->{id};
$res         = $t->await::buy({
    buy   => $proposal_id,
    price => 10000
});
is $res->{buy}->{buy_price}, '1.00';

$contractParameters{duration} = 100000000;
$res = $t->await::buy({
    buy        => 1,
    price      => 0,
    parameters => \%contractParameters,
});
is $res->{error}->{code}, 'InvalidtoBuy', 'Schema validation does not fail with huge duration';

$contractParameters{duration} = -10;
$res = $t->await::buy({
    buy        => 1,
    price      => 0,
    parameters => \%contractParameters,
});
is $res->{error}->{code}, 'InputValidationFailed', 'Schema validation fails with negative duration';

subtest 'buy and subscribe' => sub {

    my $proposal_3 = $t->await::proposal({
        proposal => 1,
        %notouch_2
    });

    $proposal_id = $proposal_3->{proposal}->{id};
    $res         = $t->await::buy({
        buy         => $proposal_id,
        price       => 10000,
        "subscribe" => "1",
        req_id      => 1111,
    });

    my $contract_id;
    diag explain $res unless ok($contract_id = $res->{buy}->{contract_id}, "got contract_id");

    is $res->{req_id}, 1111, 'same req_id in response'; 

    my @buy_keys = sort qw/balance_after shortcode contract_id start_time longcode transaction_id buy_price purchase_time payout/;

    is_deeply([sort (keys %{$res->{buy}})], [@buy_keys], 'no unexpected response');

    ok $res->{subscription}->{id}, 'Subscription id is added';

    my $msg = {
        %$res,
        action_type             => 'buy',
        account_id              => $client->default_account->id,
        financial_market_bet_id => $res->{buy}{contract_id},
        amount                  => $res->{buy}{buy_price},
        short_code              => $res->{buy}{shortcode},
        currency_code           => 'USD',

    };

    my $json = JSON::MaybeXS->new;
    BOM::Config::RedisReplicated::redis_write()->publish('TXNUPDATE::transaction_' . $msg->{account_id}, Encode::encode_utf8($json->encode($msg)));

    sleep 2;

    my $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});
    diag explain $res if not is(scalar @{$data->{forget_all}}, 1, 'Correct number of subscription forget');
};

$t->finish_ok;

done_testing();
