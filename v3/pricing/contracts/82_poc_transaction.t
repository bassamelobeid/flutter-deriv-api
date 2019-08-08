use strict;
use warnings;
use Test::More;
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data call_mocked_client build_mojo_test/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Config::RedisReplicated;
use BOM::Database::DataMapper::FinancialMarketBet;
use BOM::Config::Runtime;
use Test::Deep;
use Encode;
use JSON::MaybeXS;
use Date::Utility;
use Test::MockModule;
use Future;

my $mocked_longcode = Test::MockModule->new('Binary::WebSocketAPI::Plugins::Longcode');
$mocked_longcode->mock('longcode', sub { return Future->done('mocked longcode') });
build_test_R_50_data();
my $t    = build_wsapi_test();
my $json = JSON::MaybeXS->new;

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

$client->account('USD');
$client->smart_payment(
    currency     => 'USD',
    amount       => +100,
    payment_type => 'external_cashier',
    remark       => 'test deposit'
);

my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
my $account_id = $client->account->id;
$t->await::authorize({authorize => $token});
my ($c) = values $t->app->active_connections->%*;
my (@global_poc_uuids, $global_data, $global_contract_id);
subtest 'forget transaction stream at first' => sub {
    my $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});
    is(scalar @{$data->{forget_all}}, 0, 'Forget all returns empty because all streams forgot already');
    my @transaction_subscriptions = Binary::WebSocketAPI::v3::Subscription::Transaction->get_by_class($c);
    is(scalar @transaction_subscriptions, 0, "There is 0 transaction subscription");
    my @pocs = Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract->get_by_class($c);
    my @poc_uuids = sort map { $_->uuid } @pocs;
    is(scalar(@poc_uuids), 0, 'There is 0 poc subscriptions now');
};

subtest 'buy a contract and subscribe all poc streams' => sub {
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

    $global_contract_id = $data->{buy}{contract_id};
    ok($global_contract_id, 'buy success');
    #subscription by poc call
    $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1,
    });
    is $data->{error}, undef, 'No error';
    test_subscriptions($c, 1);
    my @result = parse_result($c);
    @global_poc_uuids = @{$result[-1]};
};
subtest 'forget one poc subscription and test subscriptions' => sub {
    ok($t->await::forget({forget => $global_poc_uuids[0]}), "forget that poc subscription");
    test_subscriptions($c, 0);
};
subtest 'subscribe that poc stream again and test' => sub {
    my $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1,
        contract_id            => $global_contract_id,
    });
    my $poc_uuid = $data->{subscription}{id};
    ok($poc_uuid, "poc stream subscribed");
    test_subscriptions($c, 1);
    my @result    = parse_result($c);
    my @poc_uuids = @{$result[-1]};
    is($poc_uuids[0], $poc_uuid, "that poc uuid is in the stash");    #---------------
};

subtest 'buy another contract and test' => sub {
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

    $global_data = $t->await::buy({
        buy   => $proposal->{proposal}->{id},
        price => $proposal->{proposal}->{ask_price},
    });

    test_subscriptions($c, 2);
};
subtest 'sell a contract and test' => sub {
    my $contract_id = $global_data->{buy}{contract_id};

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

    BOM::Config::RedisReplicated::redis_transaction_write()
        ->publish('TXNUPDATE::transaction_' . $msg->{account_id}, Encode::encode_utf8($json->encode($msg)));

    my $data = $t->await::proposal_open_contract();
    is($data->{msg_type}, 'proposal_open_contract', 'Got message about selling contract');
    is $data->{proposal_open_contract}->{contract_id}, $contract_id, 'Contract id is correct';
    test_subscriptions($c, 1);
};
subtest 'forget all and test' => sub {
    my $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});
    is(scalar($data->{forget_all}->@*), 1, 'There is only one poc stream forgotten in the result, that means no transaction stream forgotten');
    my @transaction_subscriptions = Binary::WebSocketAPI::v3::Subscription::Transaction->get_by_class($c);
    is(scalar(@transaction_subscriptions), 0, 'but in fact all transaction streams also forgotten');
};

$t->finish_ok;

done_testing();

sub parse_result {
    my $c                                    = shift;
    my @transaction_subscriptions            = Binary::WebSocketAPI::v3::Subscription::Transaction->get_by_class($c);
    my @types                                = map { $_->type } @transaction_subscriptions;
    my @buy_type                             = grep(/^buy$/, @types);
    my @poc_uuids_in_transaction_subscripton = sort map { $_->type eq 'sell' ? $_->poc_uuid : () } @transaction_subscriptions;
    my @pocs                                 = Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract->get_by_class($c);
    my @poc_uuids                            = sort map { $_->uuid } @pocs;

    return (\@types, \@buy_type, \@poc_uuids_in_transaction_subscripton, \@poc_uuids);
}

sub test_subscriptions {
    my ($c, $num_of_poc_uuid) = @_;
    my ($types, $poc_type, $poc_uuids_in_transaction_subscripton, $poc_uuids) = parse_result($c);
    is(scalar(@$types), $num_of_poc_uuid + 1, 'There are ' . ($num_of_poc_uuid + 1) . ' streams');
    is(scalar(@$poc_type), 1, 'there is one poc transaction stream');
    is(scalar(@$poc_uuids_in_transaction_subscripton),
        $num_of_poc_uuid, "there are $num_of_poc_uuid transaction streams that track sell action already");
    # check the poc_uuids is in poc stream
    is(scalar(@$poc_uuids), $num_of_poc_uuid, "there are $num_of_poc_uuid subscriptions also");
    is_deeply($poc_uuids_in_transaction_subscripton, $poc_uuids, 'one-one map between transaction subscriptions and poc subscription');

}
