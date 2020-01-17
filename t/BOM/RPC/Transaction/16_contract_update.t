#!perl
use strict;
use warnings;

use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::MockTime::HiRes qw(set_relative_time restore_time);
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
use ExpiryQueue qw(queue_flush);

queue_flush();

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

my $mocked = Test::MockModule->new('Quant::Framework::Underlying');
$mocked->mock('spot_tick', sub { return $current_tick });

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

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
request(BOM::Platform::Context::Request->new(params => {}));

subtest 'contract_update' => sub {
    my $update_params = {
        client_ip => '127.0.0.1',
        token     => $token,
        args      => {
            contract_update => 1,
            limit_order     => {},
        }};

    $c->call_ok('contract_update', $update_params)->has_error->error_code_is('MissingContractId')
        ->error_message_is('Contract id is required to update contract');

    $update_params->{args}->{contract_id} = 123;
    delete $update_params->{token};
    # calling contract_update without authentication
    $c->call_ok('contract_update', $update_params)->has_error->error_code_is('InvalidToken')->error_message_is('The token is invalid.');

    $update_params->{token} = $token;
    $update_params->{args}->{limit_order} = {
        take_profit => 10,
    };

    $c->call_ok('contract_update', $update_params)->has_error->error_code_is('ContractNotFound')
        ->error_message_is('This contract was not found among your open positions.');

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

    $update_params->{args}->{contract_id} = $buy_res->{contract_id};
    $update_params->{args}->{limit_order} = (1);
    my $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('InvalidUpdateArgument')
        ->error_message_is('Only a hash reference input is accepted.');

    $update_params->{args}->{limit_order} = {take_profit => 'notanumberornull'};
    $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('InvalidUpdateValue')
        ->error_message_is('Please enter a number or a null value.');

    $update_params->{args}->{limit_order} = {
        something => 1,
    };
    $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('UpdateNotAllowed')
        ->error_message_is('Only updates to these parameters are allowed take_profit,stop_loss.');
    $update_params->{args}->{limit_order} = {take_profit => -0.4};
    $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('InvalidContractUpdate')
        ->error_message_is('Please enter a take profit amount that\'s higher than 0.1.');
    $update_params->{args}->{limit_order} = {take_profit => 10};
    $res = $c->call_ok('contract_update', $update_params)->has_no_error->result;
    ok $res->{take_profit}, 'returns the new take profit value';
    is $res->{take_profit}->{order_amount}, 10, 'correct take profit order_amount';
    ok !%{$res->{stop_loss}}, 'stop loss is undef';

    delete $update_params->{args}->{limit_order}->{take_profit};
    $update_params->{args}->{limit_order}->{stop_loss} = 80;
    $res = $c->call_ok('contract_update', $update_params)->has_no_error->result;
    ok $res->{take_profit},      'returns the new take profit value';
    is $res->{take_profit}->{order_amount}, 10, 'correct take profit order_amount';
    ok $res->{stop_loss},        'returns the new stop loss value';
    is $res->{stop_loss}->{order_amount}, -80, 'correct stop loss order_amount';
    # sell_time cannot be equals to purchase_time, hence the sleep.
    sleep 1;

    my $sell_params = {
        client_ip => '127.0.0.1',
        token     => $token,
        args      => {
            sell  => $buy_res->{contract_id},
            price => 99.50
        }};
    my $sell_res = $c->call_ok('sell', $sell_params)->has_no_error->result;

    is $sell_res->{sold_for}, '99.50', 'sold for 99.50';
    # try to update after it is sold
    $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('ContractIsSold')->error_message_is('Contract has expired.');

    delete $update_params->{args}->{limit_order};
    $res = $c->call_ok('contract_update_history', $update_params)->has_no_error->result;
    is $res->[0]->{display_name}, 'Stop loss';
    is $res->[0]->{order_amount}, -80;
    is $res->[1]->{display_name}, 'Take profit';
    is $res->[1]->{order_amount}, 10;
};

done_testing();
