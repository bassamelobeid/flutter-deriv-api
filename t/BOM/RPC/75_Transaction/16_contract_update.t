#!perl
use strict;
use warnings;

use Test::Most;
use Test::Mojo;
use Test::MockTime::HiRes qw(set_relative_time restore_time);
use Test::MockModule;
use Test::Deep;
use Test::Warnings;

use Date::Utility;
use Data::Dumper;

use BOM::Pricing::v3::Contract;
use BOM::Platform::Context qw (request);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::Client qw(top_up);
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

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxAUDJPY',
        epoch      => $_,
        quote      => 100
    }) for ($now->epoch, $now->epoch + 1, $now->epoch + 5);

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

my $mocked = Test::MockModule->new('BOM::Product::Contract::Multup');
$mocked->mock('current_tick',               sub { return $current_tick });
$mocked->mock('maximum_feed_delay_seconds', sub { return 300 });

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
        ->error_message_is('Please enter a take profit amount that\'s higher than 0.10.');
    $update_params->{args}->{limit_order} = {take_profit => 10};
    $res = $c->call_ok('contract_update', $update_params)->has_no_error->result;
    ok $res->{take_profit}, 'returns the new take profit value';
    is $res->{take_profit}->{order_amount}, 10, 'correct take profit order_amount';
    ok !%{$res->{stop_loss}}, 'stop loss is undef';

    delete $update_params->{args}->{limit_order}->{take_profit};
    $update_params->{args}->{limit_order}->{stop_loss} = 80;
    $res = $c->call_ok('contract_update', $update_params)->has_no_error->result;
    ok $res->{take_profit}, 'returns the new take profit value';
    is $res->{take_profit}->{order_amount}, 10, 'correct take profit order_amount';
    ok $res->{stop_loss}, 'returns the new stop loss value';
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
    $update_params->{args}->{limit} = 5000;
    $res = $c->call_ok('contract_update_history', $update_params)->has_no_error->result;
    is $res->[0]->{display_name}, 'Take profit';
    is $res->[0]->{order_amount}, 10;
    is $res->[1]->{display_name}, 'Stop loss';
    is $res->[1]->{order_amount}, -80;

    # contract update history
    my $update_history_params = {
        client_ip => '127.0.0.1',
        token     => $token,
        args      => {
            contract_update_history => 1,
            contract_id             => 123,
            limit                   => 5000,
        }};

    $c->call_ok('contract_update_history', $update_history_params)->has_error->error_code_is('ContractUpdateHistoryFailure')
        ->error_message_is('This contract was not found among your open positions.');

    $update_history_params->{args}{contract_id} = $buy_res->{contract_id};
    my $history = $c->call_ok('contract_update_history', $update_history_params)->has_no_error->result;
    is $history->[0]->{display_name}, 'Take profit';
    is $history->[0]->{order_amount}, 10;
    is $history->[0]->{value},        101.05;
    is $history->[1]->{display_name}, 'Stop loss';
    is $history->[1]->{order_amount}, -80;
    is $history->[1]->{value},        92.05;
};

my $mock_calendar = Test::MockModule->new('Finance::Calendar');
$mock_calendar->mock(
    is_open_at => sub { 1 },
    is_open    => sub { 1 },
    trades_on  => sub { 1 });

subtest 'forex major pair - frxAUDJPY [VRTC]' => sub {
    note "commission on forex is a function of spread seasonality. So it changes throughout the day";

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
        },
        args => {price => 100},
    };
    my $buy_res = $c->call_ok('buy', $buy_params)->has_no_error->result;

    ok $buy_res->{contract_id}, 'contract is bought successfully with contract id';
    ok !$buy_res->{contract_details}->{is_sold}, 'not sold';

    my $update_params = {
        client_ip => '127.0.0.1',
        token     => $token,
        args      => {
            contract_id     => $buy_res->{contract_id},
            contract_update => 1,
            limit_order     => {
                take_profit => 10,
                stop_loss   => 15
            },
        }};
    my $update_res = $c->call_ok('contract_update', $update_params)->has_no_error->result;
    is $update_res->{stop_loss}->{order_amount}, -15;
    ok $update_res->{stop_loss}->{value};
    is $update_res->{take_profit}->{order_amount}, 10;
    ok $update_res->{take_profit}->{value};
};

my $mock_client = Test::MockModule->new('BOM::User::Client');
$mock_client->mock(is_tnc_approval_required => sub { 0 });

my $mx = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    email       => $email,
});
$mx->status->set('age_verification', 'system', 'age verified');
top_up $mx, 'USD', 1000;
my ($mx_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx->loginid);

subtest 'multiplier on MX' => sub {
    note "commission on forex is a function of spread seasonality. So it changes throughout the day";

    my $buy_params = {
        client_ip           => '127.0.0.1',
        token               => $mx_token,
        contract_parameters => {
            contract_type => 'MULTUP',
            basis         => 'stake',
            amount        => 100,
            multiplier    => 50,
            symbol        => 'frxAUDJPY',
            currency      => 'USD',
        },
        args => {price => 100},
    };
    my $buy_res = $c->call_ok('buy', $buy_params)->has_error->error_code_is('NotLegalContractCategory')
        ->error_message_is('Please switch accounts to trade this contract.');
};

my $mx_uk = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MX',
    residence   => 'gb',
    email       => $email,
});
$mx_uk->status->set('age_verification', 'system', 'age verified');
top_up $mx_uk, 'USD', 1000;
my ($mx_uk_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mx_uk->loginid);

subtest 'multiplier on MX [with UK residence]' => sub {
    note "commission on forex is a function of spread seasonality. So it changes throughout the day";

    my $buy_params = {
        client_ip           => '127.0.0.1',
        token               => $mx_uk_token,
        contract_parameters => {
            contract_type => 'MULTUP',
            basis         => 'stake',
            amount        => 100,
            multiplier    => 50,
            symbol        => 'frxAUDJPY',
            currency      => 'USD',
        },
        args => {price => 100},
    };
    $c->call_ok('buy', $buy_params)->has_error->error_code_is('NotLegalContractCategory')
        ->error_message_is('Please switch accounts to trade this contract.');

    $buy_params->{contract_parameters}{symbol} = 'R_100';
    my $buy_res = $c->call_ok('buy', $buy_params)->has_error->error_code_is('NotLegalContractCategory')
        ->error_message_is('Please switch accounts to trade this contract.');

};

my $mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    email       => $email,
});
$mf->status->set('age_verification', 'system', 'age verified');

note('mocking all compliance checks to true');
$mocked = Test::MockModule->new('BOM::Transaction::Validation');
$mocked->mock('check_tax_information',         sub { return undef });
$mocked->mock('compliance_checks',             sub { return undef });
$mocked->mock('check_client_professional',     sub { return undef });
$mocked->mock('check_authentication_required', sub { return undef });
$mocked->mock('_validate_client_status',       sub { return undef });

top_up $mf, 'USD', 1000;
my ($mf_token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $mf->loginid);

subtest 'multiplier on MF' => sub {
    note "commission on forex is a function of spread seasonality. So it changes throughout the day";

    my $buy_params = {
        client_ip           => '127.0.0.1',
        token               => $mf_token,
        contract_parameters => {
            contract_type => 'MULTUP',
            basis         => 'stake',
            amount        => 100,
            multiplier    => 50,
            symbol        => 'R_100',
            currency      => 'USD',
        },
        args => {price => 100},
    };
    Test::Warnings::allow_warnings(1);
    $c->call_ok('buy', $buy_params)->has_error->error_code_is('InvalidtoBuy');
    Test::Warnings::allow_warnings(0);

    $buy_params->{contract_parameters}{symbol}     = 'frxAUDJPY';
    $buy_params->{contract_parameters}{multiplier} = 50;
    $c->call_ok('buy', $buy_params)->has_error->error_code_is('InvalidtoBuy')->error_message_is('Multiplier is not in acceptable range. Accepts 30.');

    $buy_params->{contract_parameters}{multiplier} = 30;
    my $buy_res = $c->call_ok('buy', $buy_params)->has_no_error->result;
    ok $buy_res->{contract_id}, 'buy successful';
};

done_testing();
