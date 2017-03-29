use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use LandingCompany::Offerings qw(reinitialise_offerings);

reinitialise_offerings(BOM::Platform::Runtime->instance->get_offerings_config);
initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/USD JPY JPY-USD/);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'AS51',
        recorded_date => Date::Utility->new,
    });

my $now  = Date::Utility->new;
my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    epoch      => $now->epoch,
    underlying => 'AS51',
});
my $currency   = 'USD';
my $underlying = create_underlying('AS51');

subtest 'validate client error message' => sub {

    my $mock_cal = Test::MockModule->new('Quant::Framework::TradingCalendar');
    $mock_cal->mock('is_open_at', sub { 0 });

    my $contract = produce_contract({
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => Date::Utility->new,
        duration     => '5d',
        current_tick => $tick,
        barrier      => 'S0P',
    });

    my $cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});

    my $transaction = BOM::Transaction->new({
        client   => $cr,
        contract => $contract
    });

    my $error = BOM::Transaction::Validation->new(
        client      => $cr,
        transaction => $transaction
    )->_is_valid_to_buy;

    like($error->{-message_to_client}, qr/Try out the Volatility Indices/, 'CR client got message about Volatility Indices');

# same params, but new object - not to hold prev error
    $contract = produce_contract({
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => $currency,
        payout       => 1000,
        date_start   => Date::Utility->new,
        duration     => '5d',
        current_tick => $tick,
        barrier      => 'S0P',
    });
    my $mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});

    $transaction = BOM::Transaction->new({
        client   => $mf,
        contract => $contract
    });

    $error = BOM::Transaction::Validation->new(
        client      => $mf,
        transaction => $transaction
    )->_is_valid_to_buy;

    unlike($error->{-message_to_client}, qr/Try out the Volatility Indices/, 'MF client didnt got message about Volatility Indices');

};

done_testing;
