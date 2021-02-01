#!perl
use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockModule;
use Test::Deep;
use Date::Utility;
use Data::Dumper;

use BOM::Pricing::v3::Contract;
use BOM::Platform::Context qw (request);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Config::Redis;
use ExpiryQueue;
use BOM::Config::Chronicle;
use Quant::Framework;

my $expiryq = ExpiryQueue->new(redis => BOM::Config::Redis::redis_expiryq_write);
$expiryq->queue_flush();

my $now = Date::Utility->new();

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
$client->deposit_virtual_funds;
my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client->loginid);

my $current_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'R_100',
        epoch      => $now->epoch,
        quote      => 100,
    },
    1
);

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

my $mocked = Test::MockModule->new('Quant::Framework::Underlying');
$mocked->mock('spot_tick', sub { return $current_tick });

my $mocked_emp = Test::MockModule->new('VolSurface::Empirical');
$mocked_emp->mock('get_volatility', sub { return 0.1 });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol        => 'R_100',
        recorded_date => $now
    });

my $c = BOM::Test::RPC::QueueClient->new();
request(BOM::Platform::Context::Request->new(params => {}));

subtest 'contract_update' => sub {
    my $cancel_params = {
        client_ip => '127.0.0.1',
        token     => $token,
        args      => {cancel => undef}};

    $c->call_ok('cancel', $cancel_params)->has_error->error_code_is('MissingContractId')
        ->error_message_is('Contract id is required to cancel contract');

    $cancel_params->{args}->{cancel} = 123;
    delete $cancel_params->{token};
    # calling contract_update without authentication
    $c->call_ok('cancel', $cancel_params)->has_error->error_code_is('InvalidToken')->error_message_is('The token is invalid.');

    $cancel_params->{token} = $token;

    $c->call_ok('cancel', $cancel_params)->has_error->error_code_is('ContractNotFound')->error_message_is('Contract not found for contract id: 123.');

    my $buy_params = {
        client_ip           => '127.0.0.1',
        token               => $token,
        contract_parameters => {
            contract_type => 'MULTUP',
            basis         => 'stake',
            amount        => 100,
            multiplier    => 10,
            symbol        => 'R_100',
            currency      => 'USD',
        },
        args => {price => 100},
    };
    my $buy_res = $c->call_ok('buy', $buy_params)->has_no_error->result;

    ok $buy_res->{contract_id}, 'contract is bought successfully with contract id';
    ok !$buy_res->{contract_details}->{is_sold}, 'not sold';

    $cancel_params->{args}->{cancel} = $buy_res->{contract_id};
    my $res =
        $c->call_ok('cancel', $cancel_params)->has_error->error_code_is('CancelFailed')
        ->error_message_is(
        'This contract does not include deal cancellation. Your contract can only be cancelled when you select deal cancellation in your purchase.');

    $buy_params->{contract_parameters}->{cancellation} = '1h';
    $buy_params->{args}->{price}                       = 104.35;
    $buy_res                                           = $c->call_ok('buy', $buy_params)->has_no_error->result;

    ok $buy_res->{contract_id}, 'contract is bought successfully with contract id';
    ok !$buy_res->{contract_details}->{is_sold}, 'not sold';
    sleep 1;
    $cancel_params->{args}->{cancel} = $buy_res->{contract_id};
    $res = $c->call_ok('cancel', $cancel_params)->has_no_error->result;

    ok $res->{transaction_id}, 'sold';
    is $res->{sold_for} + 0, 100, 'sold for initial stake amount';

    $buy_params = {
        client_ip           => '127.0.0.1',
        token               => $token,
        contract_parameters => {
            contract_type => 'CALL',
            basis         => 'stake',
            amount        => 100,
            symbol        => 'R_100',
            currency      => 'USD',
            duration      => 300,
            duration_unit => 's'
        },
        args => {price => 100},
    };

    $buy_res = $c->call_ok('buy', $buy_params)->has_no_error->result;

    ok $buy_res->{contract_id}, 'contract is bought successfully with contract id';
    ok !$buy_res->{contract_details}->{is_sold}, 'not sold';
    sleep 1;
    $cancel_params->{args}->{cancel} = $buy_res->{contract_id};
    $res = $c->call_ok('cancel', $cancel_params)->has_error->error_code_is('CancelFailed')
        ->error_message_is('Deal cancellation is not available for this contract.');
};

my $mock_calendar = Test::MockModule->new('Finance::Calendar');
$mock_calendar->mock(
    is_open_at => sub { 1 },
    is_open    => sub { 1 },
    trades_on  => sub { 1 });

my $mock_date = Test::MockModule->new('Date::Utility');

subtest 'forex major pair - frxAUDJPY' => sub {
    my $buy_params = {
        client_ip           => '127.0.0.1',
        token               => $token,
        contract_parameters => {
            contract_type => 'MULTUP',
            basis         => 'stake',
            amount        => 100,
            multiplier    => 100,
            symbol        => 'frxAUDJPY',
            currency      => 'USD',
            cancellation  => '1h',
        },
        args => {price => 103.50},
    };

    # Deal cancellation is not available after 21:00
    $mock_date->mock('hour' => sub { return 22 });
    $c->call_ok('buy', $buy_params)->has_error->error_code_is('InvalidtoBuy', 'InvalidtoBuy')
        ->error_message_like(qr/Deal cancellation is not available/, 'Deal cancellation is not available');

    $mock_date->mock('hour' => sub { return 20 });
    my $buy_res = $c->call_ok('buy', $buy_params)->has_no_error->result;

    ok $buy_res->{contract_id}, 'contract is bought successfully with contract id';
    ok !$buy_res->{contract_details}->{is_sold}, 'not sold';

    sleep 1;
    my $cancel_params = {
        client_ip => '127.0.0.1',
        token     => $token,
        args      => {cancel => $buy_res->{contract_id}}};

    my $cancel_res = $c->call_ok('cancel', $cancel_params)->has_no_error->result;
    ok $cancel_res->{transaction_id};
    is $cancel_res->{sold_for}, '100.00', 'sold for stake at buy';
};

done_testing();
