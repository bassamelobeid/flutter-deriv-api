use strict;
use warnings;
use Test::More;
use Test::Deep qw( cmp_deeply );

use Date::Utility;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::MarketData qw(create_underlying);
use BOM::Config::Chronicle;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Test::MockModule;
use Quant::Framework;

use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;
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

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $now
    });

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
my (undef, $call_params) = call_mocked_consumer_groups_request($t, {active_symbols => 'full'});
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

my $trading_times = $t->await::trading_times({trading_times => Date::Utility->new->date_yyyymmdd});
ok($trading_times->{trading_times});
ok($trading_times->{trading_times}->{markets});
test_schema('trading_times', $trading_times);

Cache::RedisDB->flushall;
(undef, $call_params) = call_mocked_consumer_groups_request($t, {asset_index => 1});
is $call_params->{language}, 'EN';

my $asset_index = $t->await::asset_index({asset_index => 1});
is($asset_index->{msg_type}, 'asset_index');
ok($asset_index->{asset_index});
my $got_asset_index = $asset_index->{asset_index};
test_schema('asset_index', $asset_index);

(undef, $call_params) = call_mocked_consumer_groups_request($t, {asset_index => 1});
is_deeply $got_asset_index, $asset_index->{asset_index}, 'Should use cache';

$t->finish_ok;

done_testing();
