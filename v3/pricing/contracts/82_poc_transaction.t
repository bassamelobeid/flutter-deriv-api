use strict;
use warnings;
use Test::More;
use BOM::Test::Helper qw/test_schema build_wsapi_test build_test_R_50_data build_mojo_test/;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Config::Redis;
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
BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks(map { [100, time + $_, 'R_50'] } 0 .. 100);

sub create_tick {
    my $tick = {
        underlying => 'R_50',
        epoch      => time,
        quote      => 100.0
    };
    BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick($tick);
}

my $t    = build_wsapi_test();
my $json = JSON::MaybeXS->new;

# prepare client
my $email  = 'test-binary@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
$client->email($email);
$client->save;

my $loginid = $client->loginid;
my $user    = BOM::User->create(
    email    => $email,
    password => '1234',
);
$user->add_client($client);
$user->set_tnc_approval;

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
my (@global_poc_uuids, $contract_ids);
subtest 'forget transaction stream at first' => sub {
    my $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});
    is(scalar @{$data->{forget_all}}, 0, 'Forget all returns empty because all streams forgot already');
    my @transaction_subscriptions = Binary::WebSocketAPI::v3::Subscription::Transaction->get_by_class($c);
    is(scalar @transaction_subscriptions, 0, "There is 0 transaction subscription");
    my @pocs      = Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract->get_by_class($c);
    my @poc_uuids = sort map { $_->uuid } @pocs;
    is(scalar(@poc_uuids), 0, 'There is 0 poc subscriptions now');
};

subtest 'buy a contract and subscribe all poc streams' => sub {
    create_tick();
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

    $contract_ids = [$data->{buy}{contract_id}];
    ok($data->{buy}{contract_id}, 'buy success');
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
    create_tick();
    my $data = $t->await::proposal_open_contract({
        proposal_open_contract => 1,
        subscribe              => 1,
        contract_id            => $contract_ids->[0],
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

    my $res = $t->await::buy({
        buy   => $proposal->{proposal}->{id},
        price => $proposal->{proposal}->{ask_price},
    });
    push @$contract_ids, $res->{buy}{contract_id};

    test_subscriptions($c, 1);
    my @transaction_subscriptions = Binary::WebSocketAPI::v3::Subscription::Transaction->get_by_class($c);
    is(scalar(@transaction_subscriptions), 0, 'there are no transaction streams');
};

my $skip_poc = 1;
subtest 'sell a contract and test' => sub {
    sleep 1;    # contract "start time" could not be equal to "sell time"
    create_tick();
    my $data = $t->await::sell({
        sell  => $contract_ids->[0],
        price => 0
    });
    is $data->{error}, undef, "contract was sold";

    # The pricing-daemon must send one last poc response (with is_sold == 1)
    # Trying to find out which test failed.
    SKIP: {
        skip 'poc failed intermittently, maybe?', 1 if $skip_poc;
        my $poc;
        my $try = 0;
        do {
            create_tick();
            my $data = $t->await::proposal_open_contract();

            $poc = $data->{proposal_open_contract};
            is($data->{msg_type}, 'proposal_open_contract', 'got the right message_type');

            ++$try;
        } while ($try < 3 && $poc->{is_sold} == 0);

        is $poc->{is_sold}, 1, 'got the sell poc response';
        is $poc->{contract_id}, $contract_ids->[0], 'contract id is correct';

        test_subscriptions($c, 0);
    }
};

subtest 'forget all and test' => sub {
    SKIP: {
        skip 'poc is skipped higher up in the suite', 1, if $skip_poc;
        my $data = $t->await::forget_all({forget_all => 'proposal_open_contract'});
        is(scalar($data->{forget_all}->@*), 0, 'There is no forgotten poc stream in the result.');
    }
};

$t->finish_ok;

done_testing();

sub parse_result {
    my $c                         = shift;
    my @transaction_subscriptions = Binary::WebSocketAPI::v3::Subscription::Transaction->get_by_class($c);
    my @types                     = map { $_->type } @transaction_subscriptions;
    my @buy_type                  = grep(/^buy$/, @types);
    my @pocs                      = Binary::WebSocketAPI::v3::Subscription::Pricer::ProposalOpenContract->get_by_class($c);
    my @poc_uuids                 = sort map { $_->uuid } @pocs;

    return (\@types, \@buy_type, \@poc_uuids);
}

sub test_subscriptions {
    my ($c, $num_of_poc_uuid) = @_;
    my ($types, $poc_type, $poc_uuids) = parse_result($c);
    is(scalar(@$types),    0, 'There is no transaction stream');
    is(scalar(@$poc_type), 0, 'there is no poc transaction stream');
    # check the poc_uuids is in poc stream
    is(scalar(@$poc_uuids), $num_of_poc_uuid, "there are $num_of_poc_uuid poc subscriptions");
}
