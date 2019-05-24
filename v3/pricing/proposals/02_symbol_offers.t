use strict;
use warnings;
use Test::More;
use Test::Deep qw( cmp_deeply );

use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods);
use BOM::MarketData qw(create_underlying);
use BOM::Config::Chronicle;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Test::MockModule;
use Quant::Framework;

use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_client/;
use await;

initialize_realtime_ticks_db();
use Finance::Asset;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY);
my $now = Date::Utility->new;

BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $_,
        quote      => 100,
    }) for ($now->minus_time_interval('366d')->epoch, $now->epoch);

my $tp = BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods('frxUSDJPY', $now);
BOM::Test::Data::Utility::UnitTestMarketData::create_predefined_barriers('frxUSDJPY', $_) for @$tp;
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });

BOM::Test::Data::Utility::UnitTestMarketData::create_trading_periods('frxEURUSD', $now);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => $now
    });
my $t = build_wsapi_test({language => 'EN'});

# test payout_currencies
my $payout_currencies = $t->await::payout_currencies({payout_currencies => 1});
ok($payout_currencies->{payout_currencies});
ok(grep { $_ eq 'USD' } @{$payout_currencies->{payout_currencies}});
test_schema('payout_currencies', $payout_currencies);

# test active_symbols
my (undef, $call_params) = call_mocked_client($t, {active_symbols => 'full'});
ok exists $call_params->{token};

my $active_symbols = $t->await::active_symbols({active_symbols => 'full'});
is($active_symbols->{msg_type}, 'active_symbols');
ok($active_symbols->{active_symbols});
test_schema('active_symbols', $active_symbols);

$active_symbols = $t->await::active_symbols({active_symbols => 'brief'});
ok($active_symbols->{active_symbols});
test_schema('active_symbols', $active_symbols);

# test contracts_for
my $contracts_for = $t->await::contracts_for({contracts_for => 'R_50'});
is($contracts_for->{msg_type}, 'contracts_for');
ok($contracts_for->{contracts_for});
ok($contracts_for->{contracts_for}->{available});
is($contracts_for->{contracts_for}->{feed_license}, 'realtime', 'Correct license for contracts_for');
test_schema('contracts_for', $contracts_for);

$contracts_for = $t->await::contracts_for({
    contracts_for => 'frxUSDJPY',
    product_type  => 'multi_barrier'
});

my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());
my $market_closed    = !$trading_calendar->is_open_at(create_underlying('frxUSDJPY')->exchange, Date::Utility->new);
my $no_offerings     = ($contracts_for->{error}{code} // '') eq 'InvalidSymbol';
ok(Date::Utility->new->time_hhmmss ge '18:15:00' || Date::Utility->new->time_hhmmss lt '00:15:00' || $market_closed,
    "frxUSDJPY multi barrier is unavailable at this time")
    if $no_offerings;
my $skip = $market_closed || $no_offerings;

SKIP: {
    skip "Multi barrier test does not work on the weekends or contract unavailability.", 1 if $skip;
    subtest 'contracts_for multi_barrier' => sub {
        my $contracts_for_mb = $t->await::contracts_for({
            contracts_for => 'frxUSDJPY',
            product_type  => 'multi_barrier'
        });
        ok($contracts_for_mb->{contracts_for});
        ok($contracts_for_mb->{contracts_for}->{available});
        is($contracts_for_mb->{contracts_for}->{feed_license}, 'realtime', 'Correct license for contracts_for');
        test_schema('contracts_for', $contracts_for_mb);

# test contracts_for EURUSD for forward_starting_options
        my $expected_blackouts = [['11:00:00', '13:00:00'], ['20:00:00', '23:59:59']];

        my $contracts_for_eurusd = $t->await::contracts_for({contracts_for => 'frxEURUSD'});
        ok($contracts_for_eurusd->{contracts_for});
        ok($contracts_for_eurusd->{contracts_for}->{available});
        is($contracts_for_eurusd->{contracts_for}->{feed_license}, 'realtime', 'Correct license for contracts_for');

        foreach my $contract (@{$contracts_for_eurusd->{contracts_for}->{'available'}}) {
            next if $contract->{'start_type'} ne 'forward';
            cmp_deeply $contract->{'forward_starting_options'}[0]{'blackouts'}, $expected_blackouts, "expected blackouts";
        }

        test_schema('contracts_for', $contracts_for_eurusd);
        }
}

my $trading_times = $t->await::trading_times({trading_times => Date::Utility->new->date_yyyymmdd});
ok($trading_times->{trading_times});
ok($trading_times->{trading_times}->{markets});
test_schema('trading_times', $trading_times);

Cache::RedisDB->flushall;
(undef, $call_params) = call_mocked_client($t, {asset_index => 1});
is $call_params->{language}, 'EN';

my $asset_index = $t->await::asset_index({asset_index => 1});
is($asset_index->{msg_type}, 'asset_index');
ok($asset_index->{asset_index});
my $got_asset_index = $asset_index->{asset_index};
test_schema('asset_index', $asset_index);

(undef, $call_params) = call_mocked_client($t, {asset_index => 1});
is_deeply $got_asset_index, $asset_index->{asset_index}, 'Should use cache';

$t->finish_ok;

done_testing();
