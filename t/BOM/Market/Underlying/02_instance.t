use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use File::Slurp;
use List::Util qw(max min);
use Scalar::Util qw(looks_like_number);
use Test::MockTime qw( set_absolute_time );
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use DateTime;
use Cache::RedisDB;
use Date::Utility;
use Format::Util::Numbers qw(roundnear);
use BOM::Market::SubMarket;
use BOM::Market::UnderlyingDB;
use BOM::Market::Underlying;

initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for (qw/AUD EUR GBP HKD IDR JPY NZD SGD USD XAU ZAR/);

Quant::Framework::Utils::Test::create_doc('randomindex', {
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
        rates => { 7 => 3.5 },
    });

Quant::Framework::Utils::Test::create_doc('stock', {
        chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
    });

# INCORRECT DATA in support of in_quiet_period testing, only.
# Update if you want to test some other exchange info here.
my $looks_like_currency = qr/^[A-Z]{3}/;

# reason: if we only test existing symbols, attributes are set by config file,
# and _build methods are not called.
subtest 'what happens to an undefined symbol name' => sub {
    my $symbol_undefined = BOM::Market::Underlying->new('an_undefined_symbol');
    is($symbol_undefined->display_name,            'AN_UNDEFINED_SYMBOL', 'an undefined symbol has correct display_name');
    is($symbol_undefined->translated_display_name, 'AN_UNDEFINED_SYMBOL', 'an undefined symbol has correct translated_display_name');

    is($symbol_undefined->market->name,     'config',   'an undefined symbol has correct market');
    is($symbol_undefined->instrument_type,  'config',   'an undefined symbol has correct instrument_type');
    is($symbol_undefined->feed_license,     'realtime', 'an undefined symbol has correct feed_license');
    is($symbol_undefined->display_decimals, 4,          'an undefined symbol has correct display_decimals');

    is($symbol_undefined->pipsized_value(100.1234567), 100.1235, 'an undefined symbol has correct pipsized_value');

    is($symbol_undefined->commission_level, 3,     'an undefined symbol has correct commission_level');
    is($symbol_undefined->spot_spread_size, 50,    'an undefined symbol has correct spot_spread_size');
    is($symbol_undefined->spot_spread,      0.005, 'an undefined symbol has correct spot_spread');
    is($symbol_undefined->delay_amount,     0,     'an undefined symbol has correct delay_amount');
    cmp_ok($symbol_undefined->outlier_tick,         '==', 0.10, 'an undefined symbol has correct outlier tick level');
    cmp_ok($symbol_undefined->weekend_outlier_tick, '==', 0.10, 'an undefined symbol has correct outlier tick level');
};

subtest 'display_decimals' => sub {
    subtest 'forex' => sub {
        my $symbols_decimals = {
            frxUSDJPY => 3,
            frxAUDJPY => 3
        };
        my $underlying;
        foreach my $symbol (keys %$symbols_decimals) {
            $underlying = BOM::Market::Underlying->new({symbol => $symbol});
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
            $underlying = BOM::Market::Underlying->new({symbol => $symbol});
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
            $underlying = BOM::Market::Underlying->new({symbol => $symbol});
            my $decimals = $symbols_decimals->{$symbol};
            is $underlying->display_decimals, $decimals, $symbol . ' display_decimals';
        }
        
        my $r100 = BOM::Market::Underlying->new({symbol => 'R_100'});
        is $r100->dividend_rate_for(0.5), 3.5, 'correct dividend rate';
        is $r100->dividend_rate_for(1.0), 3.5, 'correct dividend rate';

    };

    subtest 'indices' => sub {
        my $symbols_decimals = {
            DJI => 2,
            AEX => 2
        };
        my $underlying;
        foreach my $symbol (qw(DJI AEX)) {
            $underlying = BOM::Market::Underlying->new({symbol => $symbol});
            my $decimals = $symbols_decimals->{$symbol};
            is $underlying->display_decimals, $decimals, $symbol . ' display_decimals';
        }
    };

    subtest 'stocks' => sub {
        my $symbols_decimals = {
            USAAPL => 2,
            UKBAY  => 4,
        };
        my $underlying;
        foreach my $symbol (qw(USAAPL UKBAY)) {
            $underlying = BOM::Market::Underlying->new({symbol => $symbol});
            my $decimals = $symbols_decimals->{$symbol};
            is $underlying->display_decimals, $decimals, $symbol . ' display_decimals';
        }

        my $stock = BOM::Market::Underlying->new({symbol => 'USAAPL'});
        is roundnear(0.0001, $stock->dividend_rate_for(0.5)), 0.0103, 'correct dividend rate for stocks';
        is $stock->dividend_rate_for(1.0), 0.0073, 'correct dividend rate for stocks';
    };
};

subtest 'all attributes on a variety of underlyings' => sub {
    # In case we want to randomly select symbols later, there's this:
    my @symbols =
        ('frxUSDZAR', 'GDAXI', 'HSI', 'FRXUSDJPY', 'frxEURUSD', 'frxXAUUSD', 'R_100', 'frxHKDUSD', 'frxUSDEUR', 'HEARTB', 'FUTHSI_BOM', 'frxNZDAUD',);
    foreach my $symbol (@symbols) {

        my $underlying = BOM::Market::Underlying->new($symbol);
        my $market     = $underlying->market->name;
        my $markets    = scalar grep { $market eq $_ } qw(indices random commodities forex config futures);
        is($markets, 1, $symbol . ' has exactly one of our expected markets');

        my $special_market;
        if ($market eq 'config') { $special_market = 1 }

        if ($market eq 'random') {
            is($underlying->quoted_currency_symbol, '', 'Randoms are not quoted in a currency');
            is($underlying->spot_spread_size,       0,  "Randoms have no spot spread size");
        } elsif ($special_market) {
            is($underlying->quoted_currency_symbol, '', 'special markets are not quoted in a currency');
            is($underlying->spot_spread_size,       50, "special markets have default spot spread size");
        } else {
            like($underlying->quoted_currency_symbol, $looks_like_currency, 'Quoted currency symbol looks like a currency');
            isa_ok($underlying->quoted_currency, 'BOM::Market::Currency', 'Quoted currency');
            is($underlying->quoted_currency_symbol, $underlying->quoted_currency->symbol, 'Which has the same symbol');
            cmp_ok($underlying->spot_spread_size, '>',  0,   'Publically traded items have a spot spread size greater than 0');
            cmp_ok($underlying->spot_spread_size, '<=', 100, ' and less than 100');
        }

        cmp_ok($underlying->outlier_tick, '>',  0,    'Outlier tick level is positive');
        cmp_ok($underlying->outlier_tick, '<=', 0.20, ' and less than 20%.');

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
                is($underlying->asset_symbol, '', 'special markets are not based on assets');
            } else {
                is($underlying->asset_symbol, $symbol, 'Asset is also the same');
            }
        }

        is($underlying->asset_symbol, $underlying->asset->symbol, 'Asset symbol and object match') if ($underlying->asset_symbol);

        is(ref $underlying->contracts, 'HASH', 'contracts is a hash ref');
        if ($underlying->quanto_only or $market eq 'config') {
            is(scalar keys %{$underlying->contracts}, 0, 'Special things should not have contracts');
        }
        cmp_ok($underlying->commission_level, '==', int $underlying->commission_level, 'Commission level is an integer');
        cmp_ok($underlying->commission_level, '>=', 1,                                 'and it is at least 1');
        cmp_ok($underlying->commission_level, '<=', 3,                                 'but not greater than 3');

        if ($underlying->inverted) {
            isnt($underlying->system_symbol, $underlying->symbol, 'Inverted underlying has a different sysmbol than system_symbol');
        }

        like(1 / $underlying->pip_size, qr/^1[0]{2,12}$/, 'pip_size is in the right format');

        cmp_ok($underlying->display_decimals, '>=', 1,  'at least 1 decimal');
        cmp_ok($underlying->display_decimals, '<=', 12, '   but no more than 7');

        is(ref $underlying->comment,       '', 'Comment is some kind of human readable thing');
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

        ok(looks_like_number($underlying->closed_weight), 'Closed weight is numeric');
        cmp_ok($underlying->closed_weight, '>=', 0, ' nonnegative');
        cmp_ok($underlying->closed_weight, '<',  1, ' and smaller than 1');

        my $license = $underlying->feed_license;
        is((scalar grep { $license eq $_ } qw(chartonly delayed daily realtime)), 1, 'Feed license is exactly one of our allowed values');

        if ($license eq 'realtime') {
            is($underlying->delay_amount, 0, 'Realtime license means no feed delay');
        }

        like($underlying->combined_folder, qr%combined%, 'Combined folder looks reasonable enough');

        is((scalar grep { $underlying->instrument_type eq $_ } qw(forex stockindex commodities config futures)),
            1, 'Instrument type is exactly one of our allowed values');

        my $month_hence = $underlying->vol_expiry_date({
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
        my $underlying  = BOM::Market::Underlying->new($symbol);
        my @submarkets  = BOM::Market::SubMarket::Registry->find_by_market($underlying->market->name);
        my $match_count = grep { $_->name eq $underlying->submarket->name } (@submarkets);

        cmp_ok($match_count, '==', 1, $underlying->symbol . ' has a properly defined submarket.');

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
    my $u    = BOM::Market::Underlying->new('frxEURUSD');
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

    is($u->tick_at(Date::Utility->new('2009-05-11 06:10:39')->epoch)->quote,
        1.3634, "We have tick for that time and it's not the last tick received");
    is($u->tick_at(Date::Utility->new('2009-05-11 06:10:40')->epoch)->quote,
        1.3634, 'We dont have tick for that second but we do have a previous one and at least one more after that');
    is($u->tick_at(Date::Utility->new('2009-05-11 06:10:41')->epoch)->quote,
        1.3633, "We have tick for that time and it's not the last tick received");
    is($u->tick_at(Date::Utility->new('2009-05-11 06:11:26')->epoch)->quote,
        1.3634, 'That is the last tick we received but it happens to be at the exact time');
    #NOTE: Do not delete this test case. This is the scenario where we do not have the tick but we return a tick
    is($u->tick_at(Date::Utility->new('2009-05-11 06:11:27')->epoch),
        undef, "The closest tick to that time is the last tick received that day. Cannot guarantee we won't receive a closer tick later.");
};

subtest vol_expiry_date => sub {
    plan tests => 5;

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');

    my @tests = (
        ['2013-01-02', 1, 'Normal day, Wed -> Thur.'],
        ['2012-12-31', 2, 'Crosses special day 1st Jan.'],
        ['2013-01-04', 3, 'Crosses weekend.'],
        ['2009-12-24', 4, 'Crosses weekend and special day Dec 25, which happens to be on a Friday.'],
        ['2013-01-10', 1, 'Normal day, but covers Jan 11 for regression purposes.'],
    );

    foreach my $test (@tests) {
        my ($date, $expected_days, $comment) = @{$test};
        $date = Date::Utility->new($date);
        my $vol_expiry_date = $underlying->vol_expiry_date({
            from => $date,
            term => 'ON'
        });
        my $got_days = $vol_expiry_date->days_between($date);
        is($expected_days, $got_days, $comment);
    }
};
subtest 'all methods on a selection of underlyings' => sub {
    my $simulated_time = 1326957372;
    my $NZ50           = BOM::Market::Underlying->new('NZ50');
    my $FTSE           = BOM::Market::Underlying->new('FTSE');
    my $EURUSD         = BOM::Market::Underlying->new('frxEURUSD');
    my $USDEUR         = BOM::Market::Underlying->new('frxUSDEUR');
    my $USDJPY         = BOM::Market::Underlying->new('frxUSDJPY');
    my $RND50          = BOM::Market::Underlying->new('R_50');
    my $oldEU          = BOM::Market::Underlying->new('frxEURUSD', Date::Utility->new('2012-01-19 07:16:12'));
    my $nonsense       = BOM::Market::Underlying->new('nonsense');

    my $FRW_frxEURUSD_ON  = BOM::Market::Underlying->new('FRW_frxEURUSD_ON');
    my $FRW_frxEURUSD_TN  = BOM::Market::Underlying->new('FRW_frxEURUSD_TN');
    my $FRW_frxEURUSD_1W  = BOM::Market::Underlying->new('FRW_frxEURUSD_1W');
    my $FRW_frxUSDEUR_ON  = BOM::Market::Underlying->new('FRW_frxUSDEUR_ON');
    my $FRW_frxUSDEUR_1W  = BOM::Market::Underlying->new('FRW_frxUSDEUR_1W');
    my $FRW_frxUSDEUR_TN  = BOM::Market::Underlying->new('FRW_frxUSDEUR_TN');
    my $fake_forward_data = {
        epoch => time,
        open  => 1,
        quote => 1,
        high  => 1,
        low   => 1,
        ticks => 1
    };
    $FRW_frxEURUSD_ON->set_combined_realtime($fake_forward_data);
    $FRW_frxEURUSD_TN->set_combined_realtime($fake_forward_data);
    $FRW_frxEURUSD_1W->set_combined_realtime($fake_forward_data);
    $FRW_frxUSDEUR_ON->set_combined_realtime($fake_forward_data);
    $FRW_frxUSDEUR_TN->set_combined_realtime($fake_forward_data);
    $FRW_frxUSDEUR_1W->set_combined_realtime($fake_forward_data);
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
        my $date = DateTime->new(
            year  => 2012,
            month => 1,
            day   => 19
        );
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

    is($nonsense->market->name, 'nonsense',      'Nonsense symbols do not have markets');
    is($EURUSD->system_symbol,  $EURUSD->symbol, 'System symbol and symbol are same for non-inverted');
    isnt($USDEUR->system_symbol, $USDEUR->symbol, ' and different for inverted');

    # We don't have translations in the sandbox.. we should probably fix that.
    is($NZ50->display_name, $NZ50->translated_display_name, 'Translated to undefined is English');

    is($NZ50->exchange->symbol, $NZ50->exchange_name, 'Got our exchange from the provided name');

    # Assumption: EUR/USD still has the 1030 to 1330 restriction.

    my $half_ten = Date::Utility->new(Date::Utility->today->epoch + 37800);
    my $half_one = Date::Utility->new(Date::Utility->today->epoch + 48600);

    isnt($EURUSD->deny_purchase_during(Date::Utility->new($half_ten->epoch - 1), $half_one), 1, " ok a little earlier");
    isnt($EURUSD->deny_purchase_during($half_ten, Date::Utility->new($half_one->epoch + 1)),     1, " or a little later");
    isnt($EURUSD->deny_purchase_during($half_ten, Date::Utility->new($half_one->epoch + 86399)), 1, " or even into the same period tomorrow");

    my $orig_buy    = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy;
    my $orig_trades = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades;

    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy([]);
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades([]);

    is($EURUSD->is_trading_suspended, 0, 'Underlying can be traded');
    is($EURUSD->is_buying_suspended,  0, 'Underlying can be bought');

    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy([$EURUSD->symbol]);
    $EURUSD->clear_is_trading_suspended;
    $EURUSD->clear_is_buying_suspended;
    is($EURUSD->is_trading_suspended, 0, ' now traded');
    ok($EURUSD->is_buying_suspended, ' but not bought');

    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades([$EURUSD->symbol]);
    $EURUSD->clear_is_trading_suspended;
    $EURUSD->clear_is_buying_suspended;
    ok($EURUSD->is_trading_suspended, ' now not tradeable');
    ok($EURUSD->is_buying_suspended,  ' nor buyable');

    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy([]);
    $EURUSD->clear_is_trading_suspended;
    $EURUSD->clear_is_buying_suspended;
    ok($EURUSD->is_trading_suspended, ' still not tradeable');
    ok($EURUSD->is_buying_suspended,  ' nor buyable');

    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy($orig_buy);
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades($orig_trades);

    my $orig_newly_added = BOM::Platform::Runtime->instance->app_config->quants->underlyings->newly_added;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->newly_added([]);
    is($EURUSD->is_newly_added, 0, 'Underlying is not newly_added');

    BOM::Platform::Runtime->instance->app_config->quants->underlyings->newly_added(['frxEURUSD']);
    $EURUSD->clear_is_newly_added;
    is($EURUSD->is_newly_added, 1, 'Underlying is now newly_added');

    BOM::Platform::Runtime->instance->app_config->quants->underlyings->newly_added($orig_newly_added);

    my $eu_symbol       = $EURUSD->symbol;
    my $looks_like_euff = qr%$eu_symbol/\d{1,2}-[A-Z]{1}[a-z]{2}-\d{1,2}(?:-fullfeed\.csv|\.fullfeed)%;

    like($EURUSD->fullfeed_file('19-Jan-12'), $looks_like_euff, "Standard fullfeed file looks right");
    like($EURUSD->fullfeed_file('1-JUN-12'),  $looks_like_euff, "Miscapitalized fullfeed file looks right");
    like($EURUSD->fullfeed_file('1-JUN-12', 'backtest'), $looks_like_euff, "Miscapitalized fullfeed file with override dir looks right");

    throws_ok { $EURUSD->fullfeed_file(1338794173) } qr/Bad date for fullfeed_file/, 'Sending in a nonstandard date string makes things die';

    my $test_date = $oldEU->for_date;

    is($EURUSD->tick_at($test_date->epoch)->quote, '1.2859', 'tick_at has some value');
    cmp_ok($EURUSD->tick_at($test_date->epoch)->quote, '==', $oldEU->spot, 'Spot for wormholed underlying and tick_at on standard underlying match');

    cmp_ok($EURUSD->spot_tick->epoch, '>',  $test_date->epoch, 'current spot is newer than the wormhole date');
    cmp_ok($oldEU->spot_tick->epoch,  '<=', $test_date->epoch, ' plus, spot_tick for old EURUSD is NOT');
    cmp_ok($oldEU->spot_tick->epoch,  '==', 1326957371,        ' in fact, it is exactly the time we expect');

    cmp_ok($oldEU->spot,                               '==', 1.2859,           'spot for old EURUSD is correct');
    cmp_ok($USDEUR->tick_at($test_date->epoch)->quote, '==', 1 / $oldEU->spot, 'And the inverted underlying is flipped');
    my $next_tick     = $EURUSD->next_tick_after($test_date->epoch);
    my $inverted_next = $USDEUR->next_tick_after($test_date->epoch);

    cmp_ok($next_tick->quote, '==', 1.2858,       'Next Tick is');
    cmp_ok($next_tick->quote, '!=', $oldEU->spot, ' and diferent from the next_tick_after');
    is($inverted_next->quote, 1 / $next_tick->quote, ' which also gets inverted');
    is($inverted_next->epoch, $next_tick->epoch,     ' at the same time');
    cmp_ok($next_tick->epoch, 'gt', $test_date->epoch, ' which is after the test time');
    is(Date::Utility->new($next_tick->epoch)->date, $test_date->date, ' on the same day');

    subtest 'asking for very old ticks' => sub {
        is($EURUSD->tick_at(123456789),  undef, 'Undefined prices way in history when no table');
        is($EURUSD->tick_at(1242022222), undef, 'Undefined prices way in history when no data');
    };

    my $eod = BOM::Market::Exchange->new('NYSE')->closing_on(Date::Utility->new);
    foreach my $pair (qw(frxUSDJPY frxEURUSD frxAUDUSD)) {
        my $worm = BOM::Market::Underlying->new($pair, $eod->minus_time_interval('1s'));
        is($worm->is_in_quiet_period, 0, $worm->symbol . ' not in a quiet period before New York closes');
        $worm = BOM::Market::Underlying->new($pair, $eod->plus_time_interval('1s'));
        ok($worm->is_in_quiet_period, $worm->symbol . ' is quiet after New York closes');
    }

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxEURUSD',
            recorded_date => Date::Utility->new,
        });

    my $today = Date::Utility->today;
    foreach my $ul ($NZ50, $EURUSD) {
        my $prev_weight = 0;
        foreach my $days_hence (1 .. 7) {
            my $test_day      = $today->plus_time_interval($days_hence . 'd');
            my $day_weight    = $ul->weight_on($test_day);
            my $period_weight = $ul->weighted_days_in_period($today, $test_day);
            cmp_ok($day_weight, '>=', $ul->closed_weight,
                $ul->display_name . ' weight for ' . $test_day->date . ' is at least as big as the closed weight');
            cmp_ok($day_weight, '<=', 1, 'And no larger than 1');
            cmp_ok(
                roundnear(0.01, $period_weight - $prev_weight),
                '==',
                roundnear(0.01, $day_weight),
                $ul->display_name . ' period weight increased by exactly the day weight'
            );
            $prev_weight = $period_weight;
        }
    }

    is($NZ50->pipsized_value(100.234567), 100.23,   'Index values are set by pipsized_value');
    is($EURUSD->pipsized_value(1.234567), 1.23457,  'Forex values are chopped to pip size');
    is($EURUSD->pipsized_value(1.23657),  1.23657,  "Value doesn't change if it is already pipsized");
    is($USDJPY->pipsized_value(-0.0079),  -0.008,   'Negative values also can be pipsized (-0.)');
    is($USDJPY->pipsized_value(-1.0079),  -1.008,   'Negative values also can be pipsized (-1.)');
    is($EURUSD->pipsized_value(-1.23651), -1.23651, 'Any negative values also can be pipsized (-1.)');
    is($NZ50->pipsized_value(-1.61),      -1.61,    'negative values for indices can be pipsized');
    cmp_ok($EURUSD->pipsized_value(1.230061), '==', 1.23006,   'pipsized_value is numerically as expected');
    cmp_ok($EURUSD->pipsized_value(1.230061), 'eq', '1.23006', ' and string-wise, too.');
};

subtest combined_realtime => sub {
    plan tests => 7;

    my $EURUSD    = BOM::Market::Underlying->new('frxEURUSD');
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

    my $SPC = BOM::Market::Underlying->new('SPC');
    ok($SPC->trades_on($eleventh), 'SPC trades on our chosen date.');

    Cache::RedisDB->del('COMBINED_REALTIME', $SPC->symbol);

    my $ticks;
    lives_ok {
        $ticks = $SPC->get_combined_realtime;
    }
    "Can get combined realtime from previous trading day's data.";

    is $ticks, undef, "Tick for SPC is not defined";
};

subtest 'daily close crossing intradays' => sub {
    plan tests => 6;
    my %expectations = (
        'frxEURUSD' => 0,
        'frxBROUSD' => 1,
        'AS51'      => 1,
        'USAAPL'    => 1,
        'R_100'     => 0,
        'RDBULL'    => 1,
    );

    foreach my $ul (map { BOM::Market::Underlying->new($_) } (keys %expectations)) {
        is($ul->intradays_must_be_same_day, $expectations{$ul->symbol}, $ul->symbol . ' sets intradays_must_be_same_day as expected.');
    }
};

subtest 'max_suspend_trading_feed_delay' => sub {
    plan tests => 6;

    my %expectations = (
        'frxEURUSD' => 90,
        'frxBROUSD' => 120,
        'AS51'      => 90,
        'USAAPL'    => 120,
        'R_100'     => 60,
        'RDBULL'    => 60,
    );

    foreach my $ul (map { BOM::Market::Underlying->new($_) } (keys %expectations)) {
        is(
            $ul->max_suspend_trading_feed_delay->seconds,
            $expectations{$ul->symbol},
            $ul->symbol . ' sets max_suspend_trading_feed_delay as expected.'
        );
    }
};

subtest 'max_failover_feed_delay' => sub {
    plan tests => 6;
    # Right now these are all the same.. but what if they weren't?
    my %expectations = (
        'frxEURUSD' => 120,
        'frxBROUSD' => 120,
        'AS51'      => 120,
        'USAAPL'    => 180,
        'R_100'     => 120,
        'RDBULL'    => 120,
    );

    foreach my $ul (map { BOM::Market::Underlying->new($_) } (keys %expectations)) {
        is($ul->max_failover_feed_delay->seconds, $expectations{$ul->symbol}, $ul->symbol . ' sets max_failover_feed_delay as expected.');
    }
};
subtest 'last_licensed_display_epoch' => sub {
    my $time      = time;
    my $frxEURUSD = BOM::Market::Underlying->new('frxEURUSD');
    # realtime license
    ok $frxEURUSD->last_licensed_display_epoch >= $time, "Can display any realtime ticks";
    # delayed license
    my $GDAXI = BOM::Market::Underlying->new('GDAXI');
    ok $GDAXI->last_licensed_display_epoch < $time - 10 * 60, "Can't display latest 10 minutes for GDAXI";
    ok $GDAXI->last_licensed_display_epoch > $time - 20 * 60, "Can display ticks older than 20 minutes for GDAXI";
    # daily license
    my $N225  = BOM::Market::Underlying->new('N225');
    my $today = Date::Utility->today;
    my $close = $N225->exchange->closing_on($today);
    if (not $close or time < $close->epoch) {
        ok $N225->last_licensed_display_epoch < $today->epoch, "Do not display any ticks for today before opening";
    } else {
        ok $N225->last_licensed_display_epoch == $close, "Display ticks up to close epoch";
    }
    # chartonly license
    my $DJI = BOM::Market::Underlying->new('DJI');
    ok $DJI->last_licensed_display_epoch == 0, "Do not display any ticks for 'chartonly'";
};

subtest 'forward_starts_on' => sub {
    subtest 'frxUSDJPY' => sub {
        my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
        my $interval   = 300;
        subtest 'Mid-Week' => sub {
            my $date = Date::Utility->new('10-Oct-2013');

            my $expected_starts = [];
            my $epoch           = $date->epoch;
            while ($epoch <= 1381449000) {    #10 Oct 2013 23:50:00 GMT - 10 mins before 00:00 GMT.
                push @$expected_starts, $epoch;
                $epoch = $epoch + $interval;    #Intraday Interval
            }

            eq_or_diff([map { $_->epoch } (@{$underlying->forward_starts_on($date)})], $expected_starts, "Got Correct starts");
        };

        subtest 'Monday' => sub {
            my $date = Date::Utility->new('21-Oct-2013');

            my $expected_starts = [];
            my $epoch           = $date->epoch + $interval;    # Should open late because it was closed before.
            while ($epoch <= 1382399400) {                     #21 Oct 2013 23:50:00 GMT - 10 mins before 00:00 GMT.
                push @$expected_starts, $epoch;
                $epoch = $epoch + $interval;                   #Intraday Interval
            }
            eq_or_diff([map { $_->epoch } (@{$underlying->forward_starts_on($date)})], $expected_starts, "Got Correct starts");

        };

        subtest 'Friday - Closing Early' => sub {
            my $date = Date::Utility->new('11-Oct-2013');

            my $expected_starts = [];
            my $epoch           = $date->epoch;
            while ($epoch <= 1381524600) {                     #11 Oct 2013 20:50:00 GMT - Closing early friday.
                push @$expected_starts, $epoch;
                $epoch = $epoch + $interval;                   #Intraday Interval
            }
            eq_or_diff([map { $_->epoch } (@{$underlying->forward_starts_on($date)})], $expected_starts, "Got Correct starts");

        };

        subtest 'weekend' => sub {
            my $date = Date::Utility->new('12-Oct-2013');      #Saturday

            my $expected_starts = [];
            eq_or_diff($underlying->forward_starts_on($date), $expected_starts, "Got Correct starts");
        };
    };
    subtest 'N225 - lunch time' => sub {
        my $underlying = BOM::Market::Underlying->new('N225');
        my $date       = Date::Utility->new('11-Oct-2013');      #Saturday
        my $interval   = 300;

        my %lunch = (
            close_buy => 1381458300,
            open_buy  => 1381462500,
        );

        my $expected_starts = [];
        my $epoch           = 1381450200;                        #11-Oct-13 00h10GMT
        while ($epoch <= 1381470600) {                           #11-Oct-13 05h50GMT
            push @$expected_starts, $epoch unless ($epoch >= $lunch{close_buy} and $epoch <= $lunch{open_buy});

            $epoch = $epoch + $interval;                         #Intraday Interval
        }
        eq_or_diff([map { $_->epoch } (@{$underlying->forward_starts_on($date)})], $expected_starts, "Got Correct starts");
    };
};

subtest 'weekend outlier tick' => sub {
    cmp_ok(BOM::Market::Underlying->new('frxUSDJPY')->weekend_outlier_tick, '==', 0.05, 'non quanto fx weekend outlier move is 0.05');
    cmp_ok(BOM::Market::Underlying->new('frxUSDSGD')->weekend_outlier_tick, '==', 0.1,  'quanto fx weekend outlier move is 0.1');
    cmp_ok(BOM::Market::Underlying->new('frxXAUUSD')->weekend_outlier_tick, '==', 0.05, 'commodities weekend outlier move is 0.05');
    cmp_ok(
        BOM::Market::Underlying->new('AEX')->weekend_outlier_tick, '==',
        BOM::Market::Underlying->new('AEX')->outlier_tick,         'indices weekend_outlier_tick matches outlier_tick'
    );
    cmp_ok(
        BOM::Market::Underlying->new('FPFP')->weekend_outlier_tick, '==',
        BOM::Market::Underlying->new('FPFP')->outlier_tick,         'commodities weekend_outlier_tick matches outlier_tick5'
    );
    cmp_ok(
        BOM::Market::Underlying->new('R_100')->weekend_outlier_tick, '==',
        BOM::Market::Underlying->new('R_100')->outlier_tick,         'randoms weekend_outlier_tick matches outlier_tick'
    );
};

done_testing;
