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
            contract_update   => 1,
            update_parameters => {},
        }};

    $c->call_ok('contract_update', $update_params)->has_error->error_code_is('MissingContractId')
        ->error_message_is('Contract id is required to update contract');

    $update_params->{args}->{contract_id} = 123;
    delete $update_params->{token};
    # calling contract_update without authentication
    $c->call_ok('contract_update', $update_params)->has_error->error_code_is('InvalidToken')->error_message_is('The token is invalid.');

    $update_params->{token} = $token;
    $update_params->{args}->{update_parameters} = {
        take_profit => {
            operation => 'update',
            value     => 10
        }};

    $c->call_ok('contract_update', $update_params)->has_error->error_code_is('ContractNotFound')
        ->error_message_is('Contract not found for contract id: 123.');

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

    $update_params->{args}->{contract_id}       = $buy_res->{contract_id};
    $update_params->{args}->{update_parameters} = ();
    my $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('InvalidUpdateArgument')
        ->error_message_is('Update only accepts hash reference as input parameter.');

    $update_params->{args}->{update_parameters} = {take_profit => {operation => 'update'}};
    $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('ValueNotDefined')
        ->error_message_is('Value is required for update operation.');

    $update_params->{args}->{update_parameters} = {
        take_profit => {
            operation => 'something',
            value     => 10
        },
    };
    $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('UnknownUpdateOperation')
        ->error_message_is('This operation is not supported. Allowed operations (update, cancel).');

    $update_params->{args}->{update_parameters} = {
        something => {
            operation => 'update',
            value     => 10
        },
    };
    $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('UpdateNotAllowed')
        ->error_message_is('Update is not allowed for this contract. Allowed updates take_profit,stop_loss');
    $update_params->{args}->{update_parameters} = {
        take_profit => {
            operation => 'update',
            value     => -1
        },
    };
    $res = $c->call_ok('contract_update', $update_params)->has_error->error_code_is('InvalidContractUpdate')
        ->error_message_is('Invalid take profit. Take profit must be higher than current spot price.');
    $update_params->{args}->{update_parameters} = {
        take_profit => {
            operation => 'update',
            value     => 10
        },
    };
    $res = $c->call_ok('contract_update', $update_params)->has_no_error->result;
    ok $res->{status} == 1, 'contract_update status=1';
    ok $res->{barrier_value},    'has barrier value';
    is $res->{type},             'take_profit', 'type is take_profit';
    ok $res->{contract_details}, 'has contract_details';
    is $res->{contract_details}{limit_order}->[0],        'stop_out';
    is $res->{contract_details}{limit_order}->[2],        'take_profit';
    is $res->{old_contract_details}{limit_order}->[0],    'stop_out';
    is_deeply $res->{contract_details}{limit_order}->[1], $res->{old_contract_details}{limit_order}->[1];
    ok !$res->{old_contract_details}{limit_order}->[2];

    $update_params->{args}->{update_parameters} = {
        stop_loss => {
            operation => 'update',
            value => -80,
        },
    };
    $res = $c->call_ok('contract_update', $update_params)->has_no_error->result;
    ok $res->{status} == 1, 'contract_update status=1';
    ok $res->{barrier_value},    'has barrier value';
    is $res->{type},             'stop_loss', 'type is stop_loss';
    ok $res->{contract_details}, 'has contract_details';
    is $res->{contract_details}{limit_order}->[0],        'stop_loss';
    is $res->{contract_details}{limit_order}->[2],        'stop_out';
    is $res->{contract_details}{limit_order}->[4],        'take_profit';

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
};

done_testing();
