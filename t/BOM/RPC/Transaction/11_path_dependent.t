use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Database::Model::OAuth;

use BOM::Test::RPC::Client;
use Test::BOM::RPC::Contract;
use Email::Stuffer::TestLinks;

initialize_realtime_ticks_db();

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
$client->deposit_virtual_funds;

my $loginid = $client->loginid;
my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
my $app = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
my $now = Date::Utility->new('10-Mar-2015');

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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now,
    }) for ('USD', 'JPY', 'JPY-USD');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });

my @ticks_to_add = (
    [$now->epoch       => 100],
    [$now->epoch + 1   => 100.010],
    [$now->epoch + 2   => 100.020],
    [$now->epoch + 3   => 100.020],
    [$now->epoch + 4   => 100.021],
    [$now->epoch + 5   => 100.023],
    [$now->epoch + 6   => 100.027],
    [$now->epoch + 30  => 100.030],
    [$now->epoch + 60  => 100.044],
    [$now->epoch + 600 => 100.050]);

my $close_tick;
foreach my $pair (@ticks_to_add) {
    # We just want the last one to INJECT below
    # OHLC test DB does not work as expected.
    $close_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $pair->[0],
        quote      => $pair->[1],
    });
}

my $args = {
    bet_type     => 'ONETOUCH',
    underlying   => 'frxUSDJPY',
    date_start   => $now,
    date_pricing => $now,
    duration     => '10m',
    currency     => 'USD',
    payout       => 10,
    barrier      => 'S20P',
};

my ($txn);
subtest 'contract creation and purchase' => sub {
    $txn = BOM::Transaction->new({
        client              => $client,
        contract_parameters => $args,
        purchase_date       => $now,
        amount_type         => 'payout'
    });
    $txn->price($txn->contract->ask_price);

    my $error = $txn->buy(skip_validation => 1);
    ok(!$error, 'no error in buy');
};

# sleep as we want barrier to be hit
sleep 2;
subtest 'check hit tick' => sub {
    my $contract_id = $txn->contract_id;

    my $params = {
        language    => 'EN',
        token       => $token,
        source      => 1,
        contract_id => $contract_id,
    };

    my $result = $app->call_ok('proposal_open_contract', $params)->has_no_system_error->has_no_error->result;
    ok !$result->{$contract_id}->{is_sold},   'contract is not sold';
    ok !$result->{$contract_id}->{sell_spot}, 'no sell spot';
};

done_testing();
