#!/usr/bin/perl

use Test::More tests => 2;
use Test::NoWarnings;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Market::Underlying;
use Date::Utility;

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Test::MockModule;

my $now = Date::Utility->new('2016-03-18 01:00:00');
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD', recorded_date => $now});

my $fake_tick = BOM::Market::Data::Tick->new({
    underlying => 'R_100',
    epoch => $now->epoch,
    quote => 100,
});

my $bet_params = {
    underlying   => 'R_100',
    bet_type     => 'CALL',
    currency     => 'USD',
    payout       => 100,
    date_pricing => $now,
    barrier      => 'S0P',
    current_tick => $fake_tick,
};

subtest 'invalid start and expiry time' => sub {
    $bet_params->{date_start} = $bet_params->{date_expiry} = $now;
    my $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/Start and Expiry times are the same/, 'expiry = start');
    $bet_params->{date_start} = $now;
    $bet_params->{date_expiry} = $now->epoch - 1;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/Start must be before expiry/, 'expiry < start');
    $bet_params->{date_start} = $now;
    $bet_params->{date_pricing} = $now->epoch + 1;
    $bet_params->{date_expiry} = $now->epoch + 20 *60;
    $bet_params->{entry_tick} = $fake_tick;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/starts in the past/, 'start < now');
    $bet_params->{for_sale} = 1;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy if it is a recreated contract';
    $bet_params->{date_start} = $now->epoch + 1;
    $bet_params->{date_pricing} = $now;
    $bet_params->{bet_type} = 'ONETOUCH';
    $bet_params->{barrier} = 110;
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/Forward time for non-forward-starting contract type/, 'start > now for non forward starting contract type');
    $bet_params->{bet_type} = 'CALL';
    $bet_params->{barrier} = 'S0P';
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy for CALL at a forward start time';
    delete $bet_params->{for_sale};
    $c = produce_contract($bet_params);
    ok !$c->is_valid_to_buy, 'not valid to buy';
    like ($c->primary_validation_error->{message}, qr/forward-starting blackout/, 'forward starting blackout');
    $bet_params->{date_start} = $now->epoch + 5*60;
    $c = produce_contract($bet_params);
    ok $c->is_valid_to_buy, 'valid to buy';
};
