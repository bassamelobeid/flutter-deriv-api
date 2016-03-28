use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Market::AggTicks;

use BOM::Test::Runtime qw(:normal);
use Date::Utility;
use Format::Util::Numbers qw( roundnear );
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::MarketData::VolSurface::Utils;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

BOM::Market::AggTicks->new->flush;

BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom/t/data/feed/');

BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');

my $test_date = Date::Utility->new('8-Nov-12');
my $util      = BOM::MarketData::VolSurface::Utils->new();
# If this moves, the test might be otherwise wonky.
my $ro_epoch = $util->NY1700_rollover_date_on($test_date)->epoch;
is($ro_epoch, 1352412000, 'Correct rollover time');

my $date_start = $ro_epoch - (60 * 3);
my $symbol     = 'frxUSDJPY';
my $bet_type   = 'CALL';
my $barrier    = 'S3P';
my $payout     = 100;
my $currency   = 'GBP';

my $first_day = Date::Utility->new($date_start)->truncate_to_day;
my $next_day = Date::Utility->new($date_start + (3600 * 9));

foreach my $day ($first_day, $next_day) {
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'currency',
        {
            symbol        => $_,
            recorded_date => $day,
        }) for (qw/GBP JPY USD AUD EUR SGD JPY-USD/);

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => $_,
            recorded_date => $day,
        }) for qw( frxUSDJPY frxGBPJPY frxGBPUSD );
}
my $bet_params = {
    bet_type     => $bet_type,
    date_pricing => $date_start,
    date_start   => $date_start,
    date_expiry  => $date_start + 4800,
    underlying   => $symbol,
    barrier      => $barrier,
    payout       => $payout,
    currency     => $currency,
    pricing_vol  => 0.1,
};

my $first_bet;
lives_ok { $first_bet = produce_contract($bet_params); } 'Bet creation works';
is($first_bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
my $first_bet_prob = $first_bet->ask_probability->amount;

foreach my $mins (0 .. 6) {
    my $secs = $mins * 60;
    $bet_params = {
        bet_type     => $bet_type,
        date_pricing => $date_start + $secs,
        date_start   => $date_start + $secs,
        date_expiry  => $date_start + $secs + 4800,
        underlying   => $symbol,
        barrier      => $barrier,
        payout       => $payout,
        currency     => $currency,
        pricing_vol  => 0.1,
    };

    my $bet;
    lives_ok { $bet = produce_contract($bet_params); } 'Bet creation works';
    is($bet->pricing_engine_name, 'BOM::Product::Pricing::Engine::Intraday::Forex', 'Bet selected IH pricing engine.');
    cmp_ok abs($bet->ask_probability->amount - $first_bet_prob), '<=', 0.02, 'Ask probability is in the proper range.';
}

done_testing;
