#!/usr/bin/perl

use Test::More;
use Test::NoWarnings;
use Test::Exception;
use Test::MockModule;

use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Product::Pricing::Engine::NewSlope;

use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Date::Utility;

my $now = Date::Utility->new;
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('exchange',        {symbol => 'FOREX'});
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency_config', {symbol => $_}) for qw(USD JPY);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('currency',        {symbol => $_}) for qw(USD JPY JPY-USD);
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });
my $ct = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'frxUSDJPY',
    epoch      => $now->epoch,
    quote      => 100
});

subtest 'CALL probability' => sub {
    my $args = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        duration     => '10d',
        barrier      => 'S0P',
        currency     => 'USD',
        payout       => 10,
        current_tick => $ct,
    };
    my $c = produce_contract($args);
    $DB::single = 1;
    my %required_args = map { my $method = '_' . $_; $_ => $c->$method } @{BOM::Product::Pricing::Engine::NewSlope->REQUIRED_ARGS};
    1;
};
