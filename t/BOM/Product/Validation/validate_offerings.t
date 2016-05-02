#!/usr/bin/perl

use Test::More tests => 7;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
use Date::Utility;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Test::MockModule;

my $now = Date::Utility->new('2016-03-15 01:00:00');

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw(USD JPY);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch
});
my $bet_params = {
    underlying   => 'frxUSDJPY',
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 100,
    date_start   => $now,
    date_pricing => $now,
    duration     => '3d',
    barrier      => 'S0P',
    current_tick => $tick,
};

my $mocked_FA = Test::MockModule->new('Finance::Asset');
$mocked_FA->mock('cached_underlyings', sub { {} });

note("Validation runs on " . $now->datetime);
subtest 'system wide suspend trading' => sub {
    BOM::Platform::Runtime->instance->app_config->system->suspend->trading(1);
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/All trading suspended on system/, 'trading suspended message');
    BOM::Platform::Runtime->instance->app_config->system->suspend->trading(0);
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'ok to buy';
};

subtest 'suspend trade on underlyings' => sub {
    my $mocked = Test::MockModule->new('BOM::Market::Underlying');
    $mocked->mock('contracts', sub { {} });
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/Underlying trades suspended/, 'Underlying trades suspended message');
    $mocked->unmock_all();
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'ok to buy';
};

subtest 'market disabled' => sub {
    $mocked_market = Test::MockModule->new('BOM::Market');
    $mocked_market->mock('disabled', sub { 1 });
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/Underlying trades suspended/, 'Underlying trades suspended message');
    $mocked_market->unmock_all;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'ok to buy';
};

subtest 'suspend contract type' => sub {
    my $orig = BOM::Platform::Runtime->instance->app_config->quants->features->suspend_claim_types;
    BOM::Platform::Runtime->instance->app_config->quants->features->suspend_claim_types(['CALL']);
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/Trading suspended for contract type/, 'Contract type suspended message');
    BOM::Platform::Runtime->instance->app_config->quants->features->suspend_claim_types($orig);
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'ok to buy';
};

subtest 'invalid underlying - contract type combination' => sub {
    my $mocked = Test::MockModule->new('BOM::Market::Underlying');
    $mocked->mock('contracts', sub { {callput => {intraday => {spot => {euro_atm => {min => '15h', max => '1d'}}}}} });
    $bet_params->{barrier} = 'S100P';    # non atm
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/trying unauthorised combination/, 'Contract type suspended message');
    $mocked->unmock_all();
};

subtest 'disable underlying due to corporate action' => sub {
    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions(['frxUSDJPY']);
    $bet_params->{underlying} = 'frxUSDJPY';
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like($c->primary_validation_error->{message}, qr/suspended due to corporate actions/, 'Underlying suspended due to corporate action');
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions($orig);
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};
