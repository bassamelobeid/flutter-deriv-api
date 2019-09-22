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
        "duration"      => "1",
        "duration_unit" => "t"
    });

    my $data = $t->await::buy({
        buy   => $proposal->{proposal}->{id},
        price => $proposal->{proposal}->{ask_price},
    });

    diag explain $data unless ok($contract_id = $data->{buy}->{contract_id}, "got contract_id");

    #call with subscription
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

$t->finish_ok;

done_testing();
