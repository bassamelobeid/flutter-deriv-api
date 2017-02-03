#!perl

use Test::Most;
use JSON;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client/;
use Net::EmptyPort qw(empty_port);
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::System::RedisReplicated;
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
    amount       => +10000,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

$t = $t->send_ok({json => {authorize => $token}})->message_ok;
my $authorize = decode_json($t->message->[1]);
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

$t = $t->send_ok({
        json => {
            "proposal" => 1,
            %contractParameters
        }});
$t->message_ok;
my $proposal = decode_json($t->message->[1]);
ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};
test_schema('proposal', $proposal);

my $id1 = $proposal->{proposal}->{id};

$t = $t->send_ok({
        json => {
            "proposal" => 1,
            %contractParameters
        }});
$t->message_ok;
$proposal = decode_json($t->message->[1]);
ok $proposal->{proposal}->{id};
cmp_ok $id1, 'eq', $proposal->{proposal}->{id}, 'ids are the same for same parameters';

$contractParameters{amount}++;
$t = $t->send_ok({
        json => {
            "proposal" => 1,
            %contractParameters
        }});
$t->message_ok;
$proposal = decode_json($t->message->[1]);
ok $proposal->{proposal}->{id};
cmp_ok $id1, 'ne', $proposal->{proposal}->{id}, 'ids are not the same if parameters are different';
$contractParameters{amount}--;

$t = $t->send_ok({
        json => {
            "proposal"  => 1,
            "subscribe" => 1,
            %contractParameters
        }});
$t->message_ok;
$proposal = decode_json($t->message->[1]);
ok $proposal->{proposal}->{id};
ok $proposal->{proposal}->{ask_price};
test_schema('proposal', $proposal);

$t = $t->send_ok({
        json => {
            "proposal"  => 1,
            "subscribe" => 1,
            %contractParameters
        }})->message_ok;
my $err_proposal = decode_json($t->message->[1]);
cmp_ok $err_proposal->{msg_type},, 'eq', 'proposal';
cmp_ok $err_proposal->{error}->{code},, 'eq', 'AlreadySubscribed', 'AlreadySubscribed error expected';

sleep 1;
$t = $t->send_ok({
        json => {
            buy   => 1,
            price => 1,
        }})->message_ok;
my $buy_error = decode_json($t->message->[1]);
is $buy_error->{msg_type}, 'buy';
is $buy_error->{error}->{code}, 'InvalidContractProposal';

my $ask_price = $proposal->{proposal}->{ask_price};
$t = $t->send_ok({
        json => {
            buy   => $proposal->{proposal}->{id},
            price => $ask_price || 0
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

my (undef, $call_params) = call_mocked_client(
    $t,
    {
        get_corporate_actions => 1,
        symbol                => "FPFP",
        start                 => "2013-03-27",
        end                   => "2013-03-30",
    });
ok !$call_params->{token};

$t = $t->send_ok({
        json => {
            get_corporate_actions => 1,
            symbol                => "FPFP",
            start                 => "2013-03-27",
            end                   => "2013-03-30",
        }})->message_ok;
my $corporate_actions = decode_json($t->message->[1]);
is $corporate_actions->{msg_type}, 'get_corporate_actions';

(undef, $call_params) = call_mocked_client($t, {portfolio => 1});
is $call_params->{token}, $token;

$t = $t->send_ok({json => {portfolio => 1}})->message_ok;
my $portfolio = decode_json($t->message->[1]);
is $portfolio->{msg_type}, 'portfolio';
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

sleep 1;
(undef, $call_params) = call_mocked_client(
    $t,
    {
        buy        => 1,
        price      => $ask_price || 0,
        parameters => \%contractParameters,
    });
is $call_params->{token}, $token;
ok $call_params->{contract_parameters};

$t = $t->send_ok({
        json => {
            buy        => 1,
            price      => $ask_price || 0,
            parameters => \%contractParameters,
        },
    });

## skip proposal until we meet buy
while (1) {
    $t = $t->message_ok;
    my $res = decode_json($t->message->[1]);
    note explain $res;
    next if $res->{msg_type} eq 'proposal';

    # note explain $res;
    is $res->{msg_type}, 'buy';
    ok $res->{buy};
    ok $res->{buy}->{contract_id};
    ok $res->{buy}->{purchase_time};

    test_schema('buy', $res);
    last;
}

(undef, $call_params) = call_mocked_client(
    $t,
    {
        sell  => 1,
        price => $ask_price || 0,
    });
is $call_params->{token}, $token;

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

$t = $t->send_ok({
        json => {
            "proposal" => 1,
            %notouch
        }});
$t->message_ok;
my $proposal_1         = decode_json($t->message->[1]);
my $proposal_id        = $proposal_1->{proposal}->{id};
my $proposal_ask_price = $proposal_1->{proposal}->{ask_price};
my $trigger_price      = $proposal_ask_price - 2;
$t = $t->send_ok({
        json => {
            buy   => $proposal_id,
            price => $trigger_price,
        }});

$t = $t->message_ok;
my $response = decode_json($t->message->[1]);
like(
    $response->{error}{message},
    qr/The underlying market has moved too much since you priced the contract. The contract price has changed/,
    'price moved error'
);

$t = $t->send_ok({json => {forget => $proposal_1->{proposal}->{id}}})->message_ok;

my %notouch_2 = (
    "amount"        => "1000",
    "basis"         => "stake",
    "contract_type" => "NOTOUCH",
    "currency"      => "USD",
    "symbol"        => "R_100",
    "duration"      => "2",
    "duration_unit" => "m",
    "barrier"       => "+25"
);

$t = $t->send_ok({
        json => {
            "proposal" => 1,
            %notouch_2
        }});
$t->message_ok;
$proposal_1  = decode_json($t->message->[1]);
$proposal_id = $proposal_1->{proposal}->{id};
$t           = $t->send_ok({
        json => {
            buy   => $proposal_id,
            price => 100,
        }});

$t->message_ok;
$res = decode_json($t->message->[1]);
is $res->{buy}->{buy_price}, 1000 ;

$t->finish_ok;

done_testing();
