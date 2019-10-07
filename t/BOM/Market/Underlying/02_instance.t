use strict;
use warnings;

use Test::MockTime qw( set_absolute_time );
use Test::MockModule;
use Test::Exception;

use Test::Most;
use Test::Warn;
use File::Slurp;
use List::Util qw(max min);
use Scalar::Util qw(looks_like_number);
use File::Spec;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Cache::RedisDB;
use Date::Utility;
use Format::Util::Numbers qw(roundcommon);
use BOM::Config::Chronicle;
use Finance::Asset::SubMarket;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use Postgres::FeedDB::Spot;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/AUD EUR GBP HKD IDR JPY NZD SGD USD XAU ZAR/);

initialize_realtime_ticks_db();

# INCORRECT DATA in support of in_quiet_period testing, only.
# Update if you want to test some other exchange info here.
my $looks_like_currency = qr/^[A-Z]{3}/;

# reason: if we only test existing symbols, attributes are set by config file,
# and _build methods are not called.
subtest 'what happens to an undefined symbol name' => sub {
    my $symbol_undefined = create_underlying('an_undefined_symbol');
    is($symbol_undefined->display_name, 'AN_UNDEFINED_SYMBOL', 'an undefined symbol has correct display_name');

    is($symbol_undefined->instrument_type,  'config',   'an undefined symbol has correct instrument_type');
    is($symbol_undefined->feed_license,     'realtime', 'an undefined symbol has correct feed_license');
    is($symbol_undefined->display_decimals, 4,          'an undefined symbol has correct display_decimals');

    throws_ok { $symbol_undefined->pipsized_value(100.1234567) } qr/unknown underlying/, 'dies if unnown underlying calls pipsize';

    is($symbol_undefined->spot_spread_size, 50,    'an undefined symbol has correct spot_spread_size');
    is($symbol_undefined->spot_spread,      0.005, 'an undefined symbol has correct spot_spread');
    is($symbol_undefined->delay_amount,     0,     'an undefined symbol has correct delay_amount');
};

subtest 'display_decimals' => sub {
    subtest 'forex' => sub {
        my $symbols_decimals = {
            frxUSDJPY => 3,
            frxAUDJPY => 3
        };
        my $underlying;
        foreach my $symbol (keys %$symbols_decimals) {
            print "trying dd for $symbol...\n";
            $underlying = create_underlying({symbol => $symbol});
            my $decimals = $symbols_decimals->{$symbol};
            is $underlying->display_decimals, $decimals, $symbol . ' display_decimals';
        }
    };

    subtest 'commodities' => sub {
        my $symbols_decimals = {
            frxXAGUSD => 4,
            frxXAUUSD => 2
        };
        my $underlying;
        foreach my $symbol (keys %$symbols_decimals) {
            $underlying = create_underlying({symbol => $symbol});
            my $decimals = $symbols_decimals->{$symbol};
            is $underlying->display_decimals, $decimals, $symbol . ' display_decimals';
        }
    };

    subtest 'Randoms' => sub {
        my $symbols_decimals = {
            R_100 => 2,
            R_75  => 4,
            R_50  => 4
        };
        my $underlying;
        foreach my $symbol (qw(R_100 R_75 R_50)) {
            $underlying = create_underlying({symbol => $symbol});
            my $decimals = $symbols_decimals->{$symbol};
            is $underlying->display_decimals, $decimals, $symbol . ' display_decimals';
        }

        my $r100 = create_underlying({symbol => 'R_100'});
        is $r100->dividend_rate_for(0.5), 0, 'correct dividend rate';
        is $r100->dividend_rate_for(1.0), 0, 'correct dividend rate';

        my $rdbull = create_underlying({symbol => 'RDBULL'});
        is $rdbull->dividend_rate_for(0.5), -35, 'correct dividend rate';
        is $rdbull->dividend_rate_for(1.0), -35, 'correct dividend rate';

    };

    subtest 'indices' => sub {
        my $symbols_decimals = {
            DJI => 2,
            AEX => 2
        };
        my $underlying;
        foreach my $symbol (qw(DJI AEX)) {
            $underlying = create_underlying({symbol => $symbol});
            my $decimals = $symbols_decimals->{$symbol};
            is $underlying->display_decimals, $decimals, $symbol . ' display_decimals';
        }
    };

};

subtest 'all attributes on a variety of underlyings' => sub {
    # In case we want to randomly select symbols later, there's this:
    my @symbols = ('frxUSDZAR', 'GDAXI', 'HSI', 'FRXUSDJPY', 'frxEURUSD', 'frxXAUUSD', 'R_100', 'frxHKDUSD', 'frxUSDEUR', 'FUTHSI_BOM', 'frxNZDAUD',);
    foreach my $symbol (@symbols) {

        my $underlying = create_underlying($symbol);
        my $market     = $underlying->market->name;
        my $markets    = scalar grep { $market eq $_ } qw(indices volidx commodities forex config futures);
        is($markets, 1, $symbol . ' has exactly one of our expected markets');

        my $special_market;
        if ($market eq 'config') { $special_market = 1 }

        if ($market eq 'volidx') {
            is($underlying->quoted_currency_symbol, '', 'Randoms are not quoted in a currency');
            is($underlying->spot_spread_size,       0,  "Randoms have no spot spread size");
        } elsif ($special_market) {
            is($underlying->quoted_currency_symbol, '', 'special markets are not quoted in a currency');
            is($underlying->spot_spread_size,       50, "special markets have default spot spread size");
        } else {
            like($underlying->quoted_currency_symbol, $looks_like_currency, 'Quoted currency symbol looks like a currency');
            isa_ok($underlying->quoted_currency, 'Quant::Framework::Currency', 'Quoted currency');
            is($underlying->quoted_currency_symbol, $underlying->quoted_currency->symbol, 'Which has the same symbol');
            cmp_ok($underlying->spot_spread_size, '>',  0,   'Publically traded items have a spot spread size greater than 0');
            cmp_ok($underlying->spot_spread_size, '<=', 100, ' and less than 100');
        }

        is($underlying->spot_spread, $underlying->spot_spread_size * $underlying->pip_size, 'Convenience method spot_spread is correct');

        if ($market eq 'forex' or $market eq 'commodities') {
            is(uc $underlying->symbol, uc $symbol, 'Forex/commodities symbols match, but be different-cased');
            is($underlying->asset_symbol,           substr($underlying->symbol, 3, 3), 'Asset is the base currency of our pair');
            is($underlying->quoted_currency_symbol, substr($underlying->symbol, 6, 3), 'Quoted currency is the numeraire currency of our pair');
        } else {
            is($underlying->symbol, $symbol, 'Symbol match');
            if ($market eq 'futures') {
                my $ass = $underlying->asset_symbol;
                like($symbol, qr/^FUT$ass/, 'Future might have the correct asset');
            } elsif ($special_market) {
                is($underlying->asset_symbol, 'HSI', 'special markets are not based on assets');
            } else {
                is($underlying->asset_symbol, $symbol, 'Asset is also the same');
            }
        }

        is($underlying->asset_symbol, $underlying->asset->symbol, 'Asset symbol and object match') if ($underlying->asset_symbol);

        if ($underlying->inverted) {
            isnt($underlying->system_symbol, $underlying->symbol, 'Inverted underlying has a different sysmbol than system_symbol');
        }

        like(1 / $underlying->pip_size, qr/^1[0]{2,12}$/, 'pip_size is in the right format');

        cmp_ok($underlying->display_decimals, '>=', 1,  'at least 1 decimal');
        cmp_ok($underlying->display_decimals, '<=', 12, '   but no more than 7');

        is(ref $underlying->display_name,  '', 'Display name is some kind of human readable thing');
        is(ref $underlying->exchange_name, '', 'Exchange name is some kind of human readable thing');

        is(ref $underlying->inefficient_periods, 'ARRAY', 'Inefficient periods is an array ref');

        foreach my $period (@{$underlying->inefficient_periods}) {
            is(ref $period, 'HASH', ' containing a period hashref');
            foreach my $expected_key (qw(start end)) {
                ok(exists $period->{$expected_key}, '  with ' . $expected_key . ' time');
                cmp_ok($period->{$expected_key}, '==', int $period->{$expected_key}, '   which is an integer');
                cmp_ok($period->{$expected_key}, '>=', 0,                            '    non-negative');
                cmp_ok($period->{$expected_key}, '<=', 86399,                        '    and within a day');
            }
            cmp_ok($period->{start}, '<', $period->{end}, '  with the start coming before the end');
        }

        is(ref $underlying->market_convention, 'HASH', 'Market convention is a hash of values');
        is((scalar grep { exists $underlying->market_convention->{$_} } qw(delta_style delta_premium_adjusted)),
            2, ' with at least the minimal key set');

        $underlying->set_combined_realtime({
            epoch => time,
            quote => 8
        });
        my $license = $underlying->feed_license;
        is((scalar grep { $license eq $_ } qw(chartonly delayed daily realtime)), 1, 'Feed license is exactly one of our allowed values');

        if ($license eq 'realtime') {
            is($underlying->delay_amount, 0, 'Realtime license means no feed delay');
        }

        is((scalar grep { $underlying->instrument_type eq $_ } qw(forex stockindex commodities config futures)),
            1, 'Instrument type is exactly one of our allowed values');

        my $expiry_conventions = Quant::Framework::ExpiryConventions->new(
            underlying       => $underlying,
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($underlying->for_date),
            calendar         => $underlying->calendar,
        );

        my $month_hence = $expiry_conventions->vol_expiry_date({
            from => Date::Utility->today,
            term => '1M'
        });
        isa_ok($month_hence, 'Date::Utility', 'month_hence');
        my $in_days = $month_hence->days_between(Date::Utility->today);
        cmp_ok($in_days, '>=', 26, 'month hence is at least 26 days in the future');
        cmp_ok($in_days, '<=', 36, 'month hence is no more than 36 days in the future');    # Weekend + 3 holidays are possible.
    }
};

subtest 'sub market' => sub {
    my @symbols = qw(
        frxEURUSD frxUSDJPY frxGBPAUD frxNZDUSD frxUSDCHF
        GDAXI HSI AEX AS51
        frxXAUUSD frxXAGUSD frxXPDUSD
        R_100 R_75 R_25 RDBULL RDBEAR
    );

    foreach my $symbol (@symbols) {
        my $underlying  = create_underlying($symbol);
        my @submarkets  = Finance::Asset::SubMarket::Registry->find_by_market($underlying->market->name);
        my $match_count = grep { $_->name eq $underlying->submarket->name } (@submarkets);

        cmp_ok($match_count, '==', 1, $underlying->symbol . ' has a properly defined submarket.');

    }
};

subtest 'is_OTC' => sub {
    my @OTC_symbols = create_underlying_db->get_symbols_for(market => ['forex', 'commodities', 'voldix']);
    foreach my $symbol (@OTC_symbols) {
        my $underlying = create_underlying($symbol);

        is($underlying->submarket->is_OTC, 1, "$symbol submarket is OTC");
    }
    my @non_OTC_symbols,
        create_underlying_db->get_symbols_for(
        market    => 'indices',
        submarket => ['asia_oceania', 'europe_africa', 'americas', 'middle_east']);
    foreach my $symbol (@non_OTC_symbols) {
        my $underlying = create_underlying($symbol);

        is($underlying->submarket->is_OTC, 0, "$symbol submarket is non OTC");

    }
};
subtest 'tick_at' => sub {
    # Due to caching/delays, even tho we do have a tick for some previous second, if that is the last tick
    # received, we cannot guarantee that there won't be a "closer" one until the next tick is written and
    # happens to be after the time we're looking for.
    # So, to keep consistency at all times, if we cannot guarantee that the tick_at for that specific epoch
    # will always be that, we return undef.
    # This is likely to bite you if you happen to be asking for ->tick_at(now), which will only give you
    # a valid result if you received a tick at that exact second
    my $u    = create_underlying('frxEURUSD');
    my $date = Date::Utility->new('2009-05-11 06:10:39');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $date->epoch,
        quote      => 1.3634,
        bid        => 1.3631,
        ask        => 1.3637,
        underlying => 'frxEURUSD'
    });
    $date = Date::Utility->new('2009-05-11 06:10:41');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $date->epoch,
        quote      => 1.3633,
        bid        => 1.3633,
        ask        => 1.3635,
        underlying => 'frxEURUSD'
    });
    $date = Date::Utility->new('2009-05-11 06:11:26');
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $date->epoch,
        quote      => 1.3634,
        bid        => 1.3632,
        ask        => 1.3636,
        underlying => 'frxEURUSD'
    });

    is($u->spot_source->tick_at(Date::Utility->new('2009-05-11 06:10:39')->epoch)->quote,
        1.3634, "We have tick for that time and it's not the last tick received");
    is($u->spot_source->tick_at(Date::Utility->new('2009-05-11 06:10:40')->epoch)->quote,
        1.3634, 'We dont have tick for that second but we do have a previous one and at least one more after that');
    is($u->spot_source->tick_at(Date::Utility->new('2009-05-11 06:10:41')->epoch)->quote,
        1.3633, "We have tick for that time and it's not the last tick received");
    is($u->spot_source->tick_at(Date::Utility->new('2009-05-11 06:11:26')->epoch)->quote,
        1.3634, 'That is the last tick we received but it happens to be at the exact time');
    #NOTE: Do not delete this test case. This is the scenario where we do not have the tick but we return a tick
    is($u->spot_source->tick_at(Date::Utility->new('2009-05-11 06:11:27')->epoch),
        undef, "The closest tick to that time is the last tick received that day. Cannot guarantee we won't receive a closer tick later.");
};

subtest vol_expiry_date => sub {
    plan tests => 5;

    my $underlying = create_underlying('frxUSDJPY');

    my @tests = (
        ['2013-01-02', 1, 'Normal day, Wed -> Thur.'],
        ['2012-12-31', 2, 'Crosses special day 1st Jan.'],
        ['2013-01-04', 3, 'Crosses weekend.'],
        ['2009-12-24', 4, 'Crosses weekend and special day Dec 25, which happens to be on a Friday.'],
        ['2013-01-10', 1, 'Normal day, but covers Jan 11 for regression purposes.'],
    );

    my $expiry_conventions = Quant::Framework::ExpiryConventions->new(
        underlying       => $underlying,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader($underlying->for_date),
        calendar         => $underlying->calendar,
    );

    foreach my $test (@tests) {
        my ($date, $expected_days, $comment) = @{$test};
        $date = Date::Utility->new($date);
        my $vol_expiry_date = $expiry_conventions->vol_expiry_date({
            from => $date,
            term => 'ON'
        });
        my $got_days = $vol_expiry_date->days_between($date);
        is($expected_days, $got_days, $comment);
    }
};
subtest 'all methods on a selection of underlyings' => sub {
    my $simulated_time = 1326957372;
    my $AS51           = create_underlying('AS51');
    my $FTSE           = create_underlying('FTSE');
    my $EURUSD         = create_underlying('frxEURUSD');
    my $USDEUR         = create_underlying('frxUSDEUR');
    my $USDJPY         = create_underlying('frxUSDJPY');
    my $RND50          = create_underlying('R_50');
    my $oldEU          = create_underlying('frxEURUSD', Date::Utility->new('2012-01-19 07:16:12'));
    my $nonsense       = create_underlying('nonsense');

    my $FRW_frxEURUSD_ON  = create_underlying('FRW_frxEURUSD_ON');
    my $FRW_frxEURUSD_TN  = create_underlying('FRW_frxEURUSD_TN');
    my $FRW_frxEURUSD_1W  = create_underlying('FRW_frxEURUSD_1W');
    my $FRW_frxUSDEUR_ON  = create_underlying('FRW_frxUSDEUR_ON');
    my $FRW_frxUSDEUR_1W  = create_underlying('FRW_frxUSDEUR_1W');
    my $FRW_frxUSDEUR_TN  = create_underlying('FRW_frxUSDEUR_TN');
    my $fake_forward_data = {
        epoch => time,
        open  => 1,
        quote => 1,
        high  => 1,
        low   => 1,
        ticks => 1
    };

    $USDEUR->set_combined_realtime($fake_forward_data);
    lives_ok {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $simulated_time - 2,
            quote      => 1.2858,
            bid        => 1.2855,
            ask        => 1.2861,
            underlying => 'frxEURUSD'
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $simulated_time - 1,
            quote      => 1.2859,
            bid        => 1.2858,
            ask        => 1.2859,
            underlying => 'frxEURUSD'
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $simulated_time + 1,
            quote      => 1.2858,
            bid        => 1.2858,
            ask        => 1.2859,
            underlying => 'frxEURUSD'
        });
    }
    'Preparing ticks';

    lives_ok {
        my $date = Date::Utility->new('2012-01-19');
        BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
            epoch      => ($date->epoch - 86400),
            open       => 1.2746,
            high       => 1.2868,
            low        => 1.2735,
            close      => 1.2864,
            underlying => 'frxEURUSD'
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
            epoch      => ($date->epoch),
            open       => 1.2864,
            high       => 1.2972,
            low        => 1.2840,
            close      => 1.2961,
            underlying => 'frxEURUSD'
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_ohlc_daily({
            epoch      => ($date->epoch + 86400),
            open       => 1.2961,
            high       => 1.2986,
            low        => 1.2887,
            close      => 1.2933,
            underlying => 'frxEURUSD'
        });
    }
    'Preparing ohlc';

    is($EURUSD->system_symbol, $EURUSD->symbol, 'System symbol and symbol are same for non-inverted');
    isnt($USDEUR->system_symbol, $USDEUR->symbol, ' and different for inverted');

    is($AS51->exchange->symbol, $AS51->exchange_name, 'Got our exchange from the provided name');

    # Assumption: EUR/USD still has the 1030 to 1330 restriction.

    my $half_ten = Date::Utility->new(Date::Utility->today->epoch + 37800);
    my $half_one = Date::Utility->new(Date::Utility->today->epoch + 48600);

    my $eu_symbol       = $EURUSD->symbol;
    my $looks_like_euff = qr%$eu_symbol/\d{1,2}-[A-Z]{1}[a-z]{2}-\d{1,2}(?:-fullfeed\.csv|\.fullfeed)%;

    my $test_date = $oldEU->for_date;

    is($EURUSD->spot_source->tick_at($test_date->epoch)->quote, '1.2859', 'spot_source->tick_at has some value');
    cmp_ok($EURUSD->spot_source->tick_at($test_date->epoch)->quote,
        '==', $oldEU->spot, 'Spot for wormholed underlying and tick_at on standard underlying match');

    cmp_ok($EURUSD->spot_source->spot_tick->epoch, '>',  $test_date->epoch, 'current spot is newer than the wormhole date');
    cmp_ok($oldEU->spot_source->spot_tick->epoch,  '<=', $test_date->epoch, ' plus, spot_tick for old EURUSD is NOT');
    cmp_ok($oldEU->spot_source->spot_tick->epoch,  '==', 1326957371,        ' in fact, it is exactly the time we expect');

    cmp_ok($oldEU->spot,                                            '==', 1.2859,           'spot for old EURUSD is correct');
    cmp_ok($USDEUR->spot_source->tick_at($test_date->epoch)->quote, '==', 1 / $oldEU->spot, 'And the inverted underlying is flipped');
    my $next_tick     = $EURUSD->next_tick_after($test_date->epoch);
    my $inverted_next = $USDEUR->next_tick_after($test_date->epoch);

    cmp_ok($next_tick->quote, '==', 1.2858,       'Next Tick is');
    cmp_ok($next_tick->quote, '!=', $oldEU->spot, ' and diferent from the next_tick_after');
    is($inverted_next->quote, 1 / $next_tick->quote, ' which also gets inverted');
    is($inverted_next->epoch, $next_tick->epoch,     ' at the same time');
    cmp_ok($next_tick->epoch, 'gt', $test_date->epoch, ' which is after the test time');
    is(Date::Utility->new($next_tick->epoch)->date, $test_date->date, ' on the same day');

    subtest 'asking for very old ticks' => sub {
        is($EURUSD->spot_source->tick_at(123456789),  undef, 'Undefined prices way in history when no table');
        is($EURUSD->spot_source->tick_at(1242022222), undef, 'Undefined prices way in history when no data');
    };

    Quant::Framework::Utils::Test::create_doc(
        'volsurface_delta',
        {
            underlying       => create_underlying('frxEURUSD'),
            chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
            recorded_date    => Date::Utility->new,
        });

    is($AS51->pipsized_value(100.234567), 100.23,   'Index values are set by pipsized_value');
    is($EURUSD->pipsized_value(1.234567), 1.23457,  'Forex values are chopped to pip size');
    is($EURUSD->pipsized_value(1.23657),  1.23657,  "Value doesn't change if it is already pipsized");
    is($USDJPY->pipsized_value(-0.0079),  -0.008,   'Negative values also can be pipsized (-0.)');
    is($USDJPY->pipsized_value(-1.0079),  -1.008,   'Negative values also can be pipsized (-1.)');
    is($EURUSD->pipsized_value(-1.23651), -1.23651, 'Any negative values also can be pipsized (-1.)');
    is($AS51->pipsized_value(-1.61),      -1.61,    'negative values for indices can be pipsized');
    cmp_ok($EURUSD->pipsized_value(1.230061), '==', 1.23006,   'pipsized_value is numerically as expected');
    cmp_ok($EURUSD->pipsized_value(1.230061), 'eq', '1.23006', ' and string-wise, too.');
};

subtest combined_realtime => sub {
    plan tests => 7;

    my $EURUSD    = create_underlying('frxEURUSD');
    my $fake_tick = {
        epoch => time,
        quote => 8,
    };
    my $reset_value = $EURUSD->get_combined_realtime;

    ok($EURUSD->set_combined_realtime($fake_tick), 'Set fake data for combined realtime');
    is_deeply($EURUSD->get_combined_realtime, $fake_tick, 'Got back the same thing from combined realtime');
    ok($EURUSD->set_combined_realtime($reset_value), 'Set back to preexisting value');

    SKIP: {
        skip('We are potentially working with live data, so reset_value might be unset.', 1) if (not $reset_value);
        is_deeply($EURUSD->get_combined_realtime, $reset_value, 'Got back the same thing from combined realtime');
    }

    # Can we get OHLC when cache is empty and market not yet open today?
    my $eleventh = Date::Utility->new('2010-01-11 02:00:00');
    set_absolute_time($eleventh->epoch);    # before opening time

    my $SPC = create_underlying('SPC');
    ok($SPC->calendar->trades_on($SPC->exchange, $eleventh), 'SPC trades on our chosen date.');

    Cache::RedisDB->del('QUOTE', $SPC->symbol);

    my $ticks;
    lives_ok {
        $ticks = $SPC->get_combined_realtime;
    }
    "Can get combined realtime from previous trading day's data.";

    is $ticks, undef, "Tick for SPC is not defined";
};

subtest 'daily close crossing intradays' => sub {
    plan tests => 5;
    my %expectations = (
        'frxEURUSD' => 0,
        'frxBROUSD' => 1,
        'AS51'      => 1,
        'R_100'     => 0,
        'RDBULL'    => 1,
    );

    foreach my $ul (map { create_underlying($_) } (keys %expectations)) {
        is($ul->intradays_must_be_same_day, $expectations{$ul->symbol}, $ul->symbol . ' sets intradays_must_be_same_day as expected.');
    }
};

subtest 'max_suspend_trading_feed_delay' => sub {
    plan tests => 5;

    my %expectations = (
        'frxEURUSD' => 30,
        'frxBROUSD' => 300,
        'AS51'      => 300,
        'R_100'     => 300,
        'RDBULL'    => 300,
    );

    foreach my $ul (map { create_underlying($_) } (keys %expectations)) {
        is(
            $ul->max_suspend_trading_feed_delay->seconds,
            $expectations{$ul->symbol},
            $ul->symbol . ' sets max_suspend_trading_feed_delay as expected.'
        );
    }
};

subtest 'last_licensed_display_epoch' => sub {
    my $time      = time;
    my $frxEURUSD = create_underlying('frxEURUSD');
    # realtime license
    ok $frxEURUSD->last_licensed_display_epoch >= $time, "Can display any realtime ticks";
    # delayed license
    my $GDAXI = create_underlying('GDAXI');
    ok $GDAXI->last_licensed_display_epoch < $time - 10 * 60, "Can't display latest 10 minutes for GDAXI";
    ok $GDAXI->last_licensed_display_epoch > $time - 20 * 60, "Can display ticks older than 20 minutes for GDAXI";
    # daily license
    my $today = Date::Utility->today;
    my $N225  = create_underlying('N225');
    my $close = $N225->calendar->closing_on($N225->exchange, $today);
    if (not $close or time < $close->epoch) {
        ok $N225->last_licensed_display_epoch < $today->epoch, "Do not display any ticks for today before opening";
    } else {
        ok $N225->last_licensed_display_epoch == $close, "Display ticks up to close epoch";
    }
    # chartonly license
    my $DJI = create_underlying('DJI');
    ok $DJI->last_licensed_display_epoch == 0, "Do not display any ticks for 'chartonly'";
};

subtest 'risk type' => sub {
    is(create_underlying('frxUSDJPY')->risk_profile, 'medium_risk', 'USDJPY is medium risk');
    is(create_underlying('frxAUDCAD')->risk_profile, 'moderate_risk',   'AUDCAD is moderate risk');
    is(create_underlying('AEX')->risk_profile,       'medium_risk', 'AEX is medium risk');
    is(create_underlying('frxXAUUSD')->risk_profile, 'moderate_risk',   'XAUUSD is moderate risk');
    is(create_underlying('R_100')->risk_profile,     'low_risk',    'R_100 is low risk');
};

subtest 'feed failover' => sub {
    is(create_underlying('frxUSDJPY')->feed_failover, '300',  "USDJPY's feed failover is 300s");
    is(create_underlying('AEX')->feed_failover,       '300',  "AEX's feed failover is 300s");
    is(create_underlying('frxXAUUSD')->feed_failover, '300',  "XAUUSD's feed failover is 300s");
    is(create_underlying('OTC_AEX')->feed_failover,   '1200', "OTC_AEX's feed failover is 1200s");
    is(create_underlying('OTC_N225')->feed_failover,  '1800', "OTC_N225's feed failover is 1800s");
};

done_testing;
