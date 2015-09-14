use strict;
use warnings;

use Test::Most qw(-Test::Deep);
use Test::FailWarnings;
use DateTime;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use BOM::Product::ContractFactory qw(produce_contract);
use BOM::Test::Runtime qw(:normal);
use Date::Utility;
use BOM::Market::Data::Tick;
use BOM::Market::Exchange;
use BOM::Market::Underlying;
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::Platform::Runtime;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
initialize_realtime_ticks_db();

my $oft_used_date   = Date::Utility->new('2013-03-29 15:00:34');
my $an_hour_earlier = Date::Utility->new($oft_used_date->epoch - 3600);
my $that_morning    = Date::Utility->new('2013-03-29 08:43:00');

my $tick_params = {
    symbol => 'not_checked',
    epoch  => $oft_used_date->epoch,
    quote  => 100
};

my $tick = BOM::Market::Data::Tick->new($tick_params);

foreach my $symbol (qw(FOREX NYSE TSE SES ASX)) {
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'exchange',
        {
            symbol => $symbol,
            date   => Date::Utility->new,
        });
}
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'RANDOM',
        open_on_weekends => 1,
        holidays         => {},
        market_times     => {
            early_closes => {},
            standard     => {
                daily_close      => '23h59m59s',
                daily_open       => '0s',
                daily_settlement => '23h59m59s',
            },
            partial_trading => {},
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'FSE',
        currency         => 'EUR',
        delay_amount     => 15,
        trading_timezone => 'Europe/Berlin',
        holidays         => {
            "25-Dec-12"  => "Christmas Day",
            "26-Dec-12"  => "Christmas Holiday",
            "31-Dec-12"  => " New Year's Eve",
            "1-Jan-13"   => "New Year's Day",
            "29-Mar-13"  => "Good Friday",
            "1-Apr-13"   => "Easter Monday",
            "1-May-13"   => "Labpur Day",
            "24-Dec-13"  => "Christmas Eve",
            "25-Dec-13"  => "Christmas Day",
            "26-Dec-13"  => "Christmas Holiday",
            "31-Dec-13"  => "New Year's Eve",
            "2013-12-20" => "pseudo-holiday",
            "2013-12-23" => "pseudo-holiday",
            "2013-12-27" => "pseudo-holiday",
            "2013-12-30" => "pseudo-holiday",
            "1-Jan-14"   => "New Year's Day",
            "18-Apr-14"  => "Good Friday",
            "21-Apr-14"  => "Easter Monday",
            "1-May-14"   => "Labour Day",
            "25-Dec-14"  => "Christmas Day",
            "26-Dec-14"  => "Boxing Day",
            "31-Dec-14"  => "New Year's Eve",
            "2014-01-02" => "pseudo-holiday",
            "2014-01-03" => "pseudo-holiday",
        },
        market_times => {
            standard => {
                daily_close      => '16h30m',
                daily_open       => '8h',
                daily_settlement => '19h30m',
            },
            partial_trading => {
                dst_open       => '7h',
                dst_close      => '12h',
                standard_open  => '8h',
                standard_close => '13h',
            },
            dst => {
                daily_close      => '15h30m',
                daily_open       => '7h',
                daily_settlement => '18h30m'
            },
        },
        date => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'EURONEXT',
        currency         => 'EUR',
        delay_amount     => 15,
        trading_timezone => 'Europe/London',
        holidays         => {
            "1-Jan-13"   => "New Year's Day",
            "29-Mar-13"  => "Good Friday",
            "1-Apr-13"   => "Easter Monday",
            "6-May-13"   => "Early May Bank Holiday",
            "27-May-13"  => "Late May Bank Holiday",
            "26-Aug-13"  => "Summer Bank Holiday",
            "25-Dec-13"  => "Christmas Day",
            "26-Dec-13"  => "Boxing Day",
            "2013-12-20" => "pseudo-holiday",
            "2013-12-23" => "pseudo-holiday",
            "2013-12-24" => "pseudo-holiday",
            "2013-12-27" => "pseudo-holiday",
            "2013-12-30" => "pseudo-holiday",
            "2013-12-31" => "pseudo-holiday",
            "1-Jan-14"   => "New Year's Day",
            "18-Apr-14"  => "Good Friday",
            "21-Apr-14"  => "Easter Monday",
            "5-May-14"   => "Early May Bank Holiday",
            "26-May-14"  => "Late May Bank Holiday",
            "25-Aug-14"  => "Summer Bank Holiday",
            "25-Dec-14"  => "Christmas Day",
            "26-Dec-14"  => "Boxing Day",
            "2014-01-02" => "pseudo-holiday",
            "2014-01-03" => "pseudo-holiday",
        },
        market_times => {
            dst => {
                daily_close      => '15h30m',
                daily_open       => '7h',
                daily_settlement => '18h30m',
            },
            standard => {
                daily_close      => '16h30m',
                daily_open       => '8h',
                daily_settlement => '19h30m'
            },
            partial_trading => {
                dst_open       => '7h',
                dst_close      => '11h30m',
                standard_open  => '8h',
                standard_close => '12h30m',
            },
            early_closes => {
                '24-Dec-10' => '12h30m',
                '24-Dec-13' => '12h30m',
            },
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'exchange',
    {
        symbol           => 'LSE',
        currency         => 'GBP',
        delay_amount     => 15,
        trading_timezone => 'Europe/London',
        holidays         => {
            "1-Jan-13"   => "New Year's Day",
            "29-Mar-13"  => "Good Friday",
            "1-Apr-13"   => "Easter Monday",
            "6-May-13"   => "Early May Bank Holiday",
            "27-May-13"  => "Late May Bank Holiday",
            "26-Aug-13"  => "Summer Bank Holiday",
            "25-Dec-13"  => "Christmas Day",
            "26-Dec-13"  => "Boxing Day",
            "2013-12-20" => "pseudo-holiday",
            "2013-12-23" => "pseudo-holiday",
            "2013-12-24" => "pseudo-holiday",
            "2013-12-27" => "pseudo-holiday",
            "2013-12-30" => "pseudo-holiday",
            "2013-12-31" => "pseudo-holiday",
            "1-Jan-14"   => "New Year's Day",
            "18-Apr-14"  => "Good Friday",
            "21-Apr-14"  => "Easter Monday",
            "5-May-14"   => "Early May Bank Holiday",
            "26-May-14"  => "Late May Bank Holiday",
            "25-Aug-14"  => "Summer Bank Holiday",
            "25-Dec-14"  => "Christmas Day",
            "26-Dec-14"  => "Boxing Day",
            "2014-01-02" => "pseudo-holiday",
            "2014-01-03" => "pseudo-holiday",
        },
        market_times => {
            dst => {
                daily_close      => '15h30m',
                daily_open       => '7h',
                daily_settlement => '18h30m',
            },
            standard => {
                daily_close      => '16h30m',
                daily_open       => '8h',
                daily_settlement => '19h30m'
            },
            partial_trading => {
                dst_open       => '7h',
                dst_close      => '11h30m',
                standard_open  => '8h',
                standard_close => '12h30m',
            },
            early_closes => {
                '24-Dec-10' => '12h30m',
                '24-Dec-13' => '12h30m',
            },
        },
        date => Date::Utility->new,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => $an_hour_earlier,
        date          => Date::Utility->new,
    }) for (qw/USD JPY EUR AUD SGD GBP/);

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => $an_hour_earlier,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_flat',
    {
        symbol        => 'RDBULL',
        recorded_date => $an_hour_earlier,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'randomindex',
    {
        symbol        => 'RDBULL',
        recorded_date => $an_hour_earlier,
        date          => Date::Utility->new
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxEURUSD',
        recorded_date => $that_morning,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'index',
    {
        symbol        => 'GDAXI',
        date          => Date::Utility->new,
        recorded_date => $an_hour_earlier
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'volsurface_moneyness',
    {
        symbol        => 'GDAXI',
        recorded_date => $an_hour_earlier,
    });

BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
    'currency_config',
    {
        symbol => $_,
        date   => Date::Utility->new,
    }) for qw( JPY USD EUR AUD SGD );

my $orig_suspended = BOM::Platform::Runtime->instance->app_config->quants->features->suspend_claim_types;
ok(BOM::Platform::Runtime->instance->app_config->quants->features->suspend_claim_types(['RANGE']), 'Suspended RANGE bet purchases!');

subtest 'valid bet passing and stuff' => sub {

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);

    ok($bet->is_valid_to_buy, 'Valid for purchase');
    # If we look at it a few minutes later..
    $bet_params->{date_pricing} = $starting + 300;
    $bet_params->{current_tick} = BOM::Market::Data::Tick->new({
        symbol => $bet->underlying->symbol,
        epoch  => $starting + 300,
        quote  => $bet->current_spot + 2 * $bet->underlying->pip_size
    });

    $bet_params = {
        underlying   => $underlying,
        bet_type     => 'INTRADD',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting - 600,
        duration     => '30m',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    $bet = produce_contract($bet_params);

    ok($bet->is_valid_to_buy,  'Valid for purchase');
    ok($bet->is_valid_to_sell, '..and for sale-back');

    $bet_params->{bet_type}   = 'CALL';
    $bet_params->{date_start} = $oft_used_date->plus_time_interval('-1d');    # We didn't insert any data here.
    delete $bet_params->{date_pricing};
    $bet_params->{barrier}  = 'S100P';
    $bet_params->{duration} = '15m';
    $bet                    = produce_contract($bet_params);

    my $expected_reasons = [qr/Missing settlement/];
    test_error_list('sell', $bet, $expected_reasons);
};

subtest 'invalid underlying is a weak foundation' => sub {

    plan tests => 5;

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    BOM::Platform::Runtime->instance->app_config->system->suspend->trading(1);    # Cheese it, it's the cops!
    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/^All trading suspended/];
    test_error_list('buy', $bet, $expected_reasons);
    BOM::Platform::Runtime->instance->app_config->system->suspend->trading(0);    # Resume betting!

    my $old_tick = BOM::Market::Data::Tick->new({
        symbol => $bet->underlying->symbol,
        epoch  => $starting - 3600,
        quote  => 100
    });
    $bet_params->{current_tick} = $old_tick;

    $bet = produce_contract($bet_params);

    $expected_reasons = [qr/Quote.*too old/];
    test_error_list('buy', $bet, $expected_reasons);

    my $orig_trades = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades;
    $bet_params->{current_tick} = $tick;
    $bet = produce_contract($bet_params);
    ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades(['frxUSDJPY']), 'Suspending trading on this underlying.');
    $bet->underlying->clear_is_buying_suspended;
    $bet->underlying->clear_is_trading_suspended;
    $expected_reasons = [qr/^Underlying.*suspended/];
    test_error_list('buy', $bet, $expected_reasons);
    ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_trades($orig_trades), 'Restoring trading to original state..');
};

subtest 'invalid bet payout hobbling around' => sub {
    plan tests => 6;

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 10000000.34,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S8500P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/payout.*acceptable range/, qr/stake.*is not within limits/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{amount} = 0.75;
    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/stake.*is not within limits/, qr/payout.*acceptable range/];
    test_error_list('buy', $bet, $expected_reasons);
    ok($bet->primary_validation_error->message =~ $expected_reasons->[1], '..and the primary one is the most severe.');

    $bet_params->{amount} = 12.345;
    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/stake.*is not within limits/, qr/more than 2 decimal places/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{amount}   = 1e5;
    $bet_params->{currency} = 'JPY';
    $bet                    = produce_contract($bet_params);
    $expected_reasons       = [qr/Bad payout currency/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{currency} = 'USD';
    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we fix those things, it validates just fine.');
};

subtest 'invalid bet types are dull' => sub {
    plan tests => 1;

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'RANGE',
        currency     => 'USD',
        payout       => 200,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '4h',
        high_barrier => 'S100P',
        low_barrier  => 'S-100P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);
    my $expected_reasons = [qr/suspended for contract type/, qr/unauthorised.*underlying/, qr/duration.*not acceptable/];
    test_error_list('buy', $bet, $expected_reasons);
};

subtest 'invalid contract stake evokes sympathy' => sub {
    plan tests => 6;

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'CALL',
        currency     => 'USD',
        amount_type  => 'payout',
        amount       => 2,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S1000000P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/stake.*is not within limits/, qr/Barrier is outside of range/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{amount}  = 1e5;
    $bet_params->{barrier} = 'S10P';
    $bet                   = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we ask for a higher payout, it validates just fine.');

    $bet_params->{duration} = '15m';
    $bet_params->{barrier}  = 'S8500P';

    $bet = produce_contract($bet_params);

    $expected_reasons = [qr/few period.*vol/, qr/Theo probability.*below the minimum acceptable/];

    my $lookback_time = Date::Utility->new($starting - $bet->timeinyears->amount * 86400 * 365);
    my $date          = DateTime->new(
        year   => $lookback_time->year,
        month  => $lookback_time->month,
        day    => $lookback_time->day_of_month,
        hour   => $lookback_time->hour,
        minute => $lookback_time->minute,
        second => $lookback_time->second
    );
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch => $date->epoch,
        quote => 100.012,
        bid   => 100.015,
        ask   => 100.021
    });

    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{barrier} = $bet->current_spot;

    $bet = produce_contract($bet_params);

    $expected_reasons = [qr/few period.*vol/];
    test_error_list('buy', $bet, $expected_reasons);
    # This can't be corrected by changing parameters, so that's it.

    $bet_params->{duration} = '11d';
    $bet_params->{barrier}  = 'S-2P';
    $bet_params->{bet_type} = 'ONETOUCH';

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/stake.*same as.*payout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{amount_type} = 'stake';
    $bet_params->{amount}      = 0;
    $bet                       = produce_contract($bet_params);
    # stake [0] is too low for payout [0]
    #         # stake [0] is same as payout [0]
    #                 # payout amount outside acceptable range[0] acceptable range [1 - 100000]
    #
    $expected_reasons = [qr/Empty or zero stake/, qr/stake.*is not within limits/, qr/payout.*acceptable range/, qr/stake.*same as.*payout/];
    test_error_list('buy', $bet, $expected_reasons);
};

subtest 'invalid barriers knocked down for great justice' => sub {
    plan tests => 7;

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'ONETOUCH',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);
    my $expected_reasons = [qr/move below minimum/, qr/barrier.*spot.*start/, qr/stake.*same as.*payout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{barrier} = 'S1000P';
    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we ask for a further barrier, it validates just fine.');

    $bet_params->{bet_type}     = 'UPORDOWN';
    $bet_params->{high_barrier} = 'S5P';
    $bet_params->{low_barrier}  = 0.50;
    $bet_params->{duration}     = '7d';
    $bet                        = produce_contract($bet_params);
    $expected_reasons = [qr/^Mixed.*barriers/, qr/stake.*same as.*payout/, qr/Lower barrier.*25%/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{low_barrier} = 'S-100000P';    # Fine, we'll set our low barrier like you want.
    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/^Non-positive barrier/, qr/stake.*same as.*payout/, qr/Lower barrier.*25%/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{low_barrier} = 'S10P';         # Sigh, ok, then, what about this one?
    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/barriers inverted/, qr/straddle.*spot/, qr/stake.*same as.*payout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{low_barrier} = 'S5P';          # Surely this must be ok.
    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/barriers must be different/, qr/straddle.*spot/, qr/stake.*same as.*payout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{high_barrier} = 'S1000P';                        # Ok, I think I get it now.
    $bet_params->{low_barrier}  = 'S-1000P';
    $bet                        = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but with properly set barriers, it validates just fine.');
};

subtest 'volsurfaces become old and invalid' => sub {
    plan tests => 8;

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch + 10 * 86400;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'DOUBLEDOWN',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        duration     => '3d',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/volsurface recorded_date earlier than/, qr/Quote.*too old/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{date_start}   = $oft_used_date->epoch;
    $bet_params->{date_pricing} = $oft_used_date->epoch;
    $bet                        = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we are close in time, validates just fine.');

    $starting = $oft_used_date->epoch + 5 * 3600 + 600;    # Intradays are even more sensitive.

    $bet_params = {
        underlying   => $underlying,
        bet_type     => 'INTRADU',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting - 450,
        duration     => '30m',
        barrier      => 'S0P',
        current_tick => $tick,
    };
    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/^Intraday.*volsurface recorded_date/, qr/Quote.*too old/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet = produce_contract($bet_params);
    ok($bet->volsurface->set_smile_flag(1, 'fake broken surface'), 'Set smile flags');
    $expected_reasons = [qr/^Intraday.*volsurface recorded_date/, qr/has smile flags/, qr/Quote.*too old/];
    test_error_list('buy', $bet, $expected_reasons);

    my $volsurface = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'GDAXI',
            recorded_date => Date::Utility->new('2013-03-27 06:00:34'),
        });

    my $gdaxi = BOM::Market::Underlying->new('GDAXI');
    $bet_params->{underlying} = $gdaxi;
    my $surface_too_old_date = $gdaxi->exchange->opening_on(Date::Utility->new('2013-03-28'));
    $bet_params->{date_start} = $bet_params->{date_pricing} = $surface_too_old_date->plus_time_interval('2h23m20s');
    $bet_params->{bet_type}   = 'ONETOUCH';
    $bet_params->{barrier}    = 103;
    $bet_params->{duration}   = '14d';
    $bet_params->{volsurface} = $volsurface;
    $bet_params->{current_tick} = $tick;
    $bet                        = produce_contract($bet_params);
    $expected_reasons           = [qr/^Index.*volsurface recorded_date greater than four hours old/];

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc('correlation_matrix', {date => Date::Utility->new()});

    test_error_list('buy', $bet, $expected_reasons);

    my $forced_vol = '0.10';
    $bet_params->{pricing_vol} = $forced_vol;
    $bet = produce_contract($bet_params);
    is($bet->pricing_args->{iv}, $forced_vol, 'Pricing args contains proper forced vol.');
    $expected_reasons = [qr/^Index.*volsurface recorded_date greater than four hours old/, qr/forced \(not calculated\) IV/];
    test_error_list('buy', $bet, $expected_reasons);
};

subtest 'invalid start times' => sub {
    plan tests => 16;

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'ONETOUCH',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting - 300,
        duration     => '3d',
        barrier      => 'S200P',
        current_tick => $tick,
    };

    my $bet = produce_contract($bet_params);

    my $expected_reasons = [qr/^Forward time for non-forward-starting/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{date_pricing} = $starting;
    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we are starting now, validates just fine.');

    $bet_params->{bet_type} = 'CALL';
    $bet_params->{duration} = '-1m';

    $bet = produce_contract($bet_params);

    $expected_reasons = [qr/^Start must be before expiry/, qr/Intraday duration.*not acceptable/, qr/Missing settlement/, qr/already expired/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '6d';

    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when back to the future, validates just fine.');

    $bet_params->{underlying}   = BOM::Market::Underlying->new('frxEURUSD');
    $bet_params->{duration}     = '10m';
    $bet_params->{bet_type}     = 'INTRADU';
    $bet_params->{date_pricing} = $starting - 30;
    $bet_params->{barrier}      = 'S0P';

    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/^Intraday.*volsurface recorded_date/, qr/forward-starting.*blackout/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{date_pricing} = $starting + 45;
    $bet_params->{bet_type}     = 'CALL';
    $bet_params->{duration}     = '3d';

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/starts in the past/];
    test_error_list('buy', $bet, $expected_reasons);

    $underlying = BOM::Market::Underlying->new('GDAXI');

    $bet_params->{underlying}   = $underlying;
    $bet_params->{bet_type}     = 'DOUBLEDOWN';
    $bet_params->{duration}     = '7d';
    $bet_params->{date_start}   = $underlying->exchange->opening_on(Date::Utility->new('2013-03-28'));
    $bet_params->{date_pricing} = $bet_params->{date_start};

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/underlying.*in starting blackout/];
    test_error_list('buy', $bet, $expected_reasons);

    my $volsurface = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'GDAXI',
            recorded_date => Date::Utility->new('2013-03-30 15:00:34'),
        });

    $bet_params->{volsurface}   = $volsurface;
    $bet_params->{bet_type}     = 'DOUBLEDOWN';
    $bet_params->{duration}     = '0d';
    $bet_params->{date_start}   = $underlying->exchange->closing_on(Date::Utility->new('2013-03-28'))->minus_time_interval('1m');
    $bet_params->{date_pricing} = $bet_params->{date_start};

    $bet = produce_contract($bet_params);
    $expected_reasons = [qr/end of day start blackout/, qr/Daily duration.*is outside/];
    test_error_list('buy', $bet, $expected_reasons);

    $volsurface = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'GDAXI',
            recorded_date => Date::Utility->new('2013-03-30 11:00:34'),
        });

    $bet_params->{date_start}   = Date::Utility->new('2013-03-30 12:34:56');    # It's a Saturday!
    $bet_params->{duration}     = '5d';
    $bet_params->{date_pricing} = $bet_params->{date_start};
    $bet_params->{volsurface}   = $volsurface;

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/underlying.*closed/];
    test_error_list('buy', $bet, $expected_reasons);

    my $orig_list = BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface;
    my $list      = '{"indices" : {"europe_africa" : ["GDAXI"]}}';
    ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface($list), 'Set');

    my $volsurface_with_unacceptable_calibration_error = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol            => 'GDAXI',
            recorded_date     => Date::Utility->new('2013-03-28 09:00:34'),
            calibration_error => 110,
        });

    $bet_params->{duration}     = '5d';
    $bet_params->{date_start}   = Date::Utility->new('2013-03-28 11:00:00');
    $bet_params->{date_pricing} = $bet_params->{date_start};
    $bet_params->{volsurface}   = $volsurface_with_unacceptable_calibration_error;
    $bet                        = produce_contract($bet_params);
    $expected_reasons           = [qr/Calibration fit outside acceptable/];
    test_error_list('buy', $bet, $expected_reasons);

    my $volsurface_with_acceptable_error = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol            => 'GDAXI',
            recorded_date     => Date::Utility->new('2013-03-28 09:00:34'),
            calibration_error => 99,
        });

    $bet_params->{volsurface} = $volsurface_with_acceptable_error;
    $bet = produce_contract($bet_params);
    ok $bet->is_valid_to_buy, 'atm bets is valid to buy if calibration fit is < 100';

    my $volsurface_with_calibration_error_unacceptable_for_IVbets = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol            => 'GDAXI',
            recorded_date     => Date::Utility->new('2013-03-28 09:00:34'),
            calibration_error => 21,
        });

    $bet_params->{duration}   = '0d';
    $bet_params->{volsurface} = $volsurface_with_calibration_error_unacceptable_for_IVbets;
    $bet                      = produce_contract($bet_params);
    $expected_reasons         = [qr/duration.*outside/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{bet_type}     = 'ONETOUCH';
    $bet_params->{barrier}      = 1.36;
    $bet_params->{duration}     = '14d';
    $bet_params->{current_tick} = $tick;
    $bet                        = produce_contract($bet_params);
    $expected_reasons = [qr/Calibration fit outside acceptable range for IV/, qr/Barrier is outside of range/];
    test_error_list('buy', $bet, $expected_reasons);
    ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface("{}"),       'Set');
    ok(BOM::Platform::Runtime->instance->app_config->quants->underlyings->price_with_parameterized_surface($orig_list), 'restored original list');
};

subtest 'invalid expiry times' => sub {
    plan tests => 5;

    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'DOUBLEDOWN',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting,
        date_expiry  => $oft_used_date->truncate_to_day->plus_time_interval('1d23h59m59s'),
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $bet              = produce_contract($bet_params);
    my $expected_reasons = [qr/^Exchange is closed on expiry date/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '3d';
    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we are open at the end, validates just fine.');

    # Need a quotdian here.
    $underlying                 = BOM::Market::Underlying->new('RDBULL');
    $bet_params->{underlying}   = $underlying;
    $bet_params->{bet_type}     = 'INTRADD';
    $bet_params->{duration}     = '10h';
    $bet_params->{date_start}   = $underlying->exchange->closing_on(Date::Utility->new('2013-03-28'))->minus_time_interval('9h');
    $bet_params->{date_pricing} = $bet_params->{date_start}->epoch - 1776;

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/must expire on same day/];
    test_error_list('buy', $bet, $expected_reasons);

    $underlying = BOM::Market::Underlying->new('GDAXI');

    my $volsurface = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'GDAXI',
            recorded_date => Date::Utility->new('2013-03-28 15:00:34'),
        });

    $bet_params->{volsurface}   = $volsurface;
    $bet_params->{underlying}   = $underlying;
    $bet_params->{duration}     = '2h';
    $bet_params->{date_start}   = $underlying->exchange->closing_on(Date::Utility->new('2013-03-28'))->minus_time_interval('1h');
    $bet_params->{date_pricing} = $bet_params->{date_start}->epoch - 1066;

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/closed at expiry/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '59m34s';

    $bet              = produce_contract($bet_params);
    $expected_reasons = [qr/end of day expiration blackout/];
    test_error_list('buy', $bet, $expected_reasons);

};

subtest 'invalid lifetimes.. how rude' => sub {
    plan tests => 10;

    my $underlying = BOM::Market::Underlying->new('frxEURUSD');
    my $starting   = $oft_used_date->epoch - 3600;

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'INTRADD',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        date_pricing => $starting - 900,
        duration     => '21s',
        barrier      => 'S0P',
        current_tick => $tick,
    };

    my $bet              = produce_contract($bet_params);
    my $expected_reasons = [qr/Intraday duration.*not acceptable/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '20m';
    $bet = produce_contract($bet_params);

    ok($bet->is_valid_to_buy, '..but when we pick a longer duration, validates just fine.');

    $bet_params->{bet_type}     = 'CALL';
    $bet_params->{duration}     = '369d';
    $bet_params->{date_start}   = $starting;
    $bet_params->{date_pricing} = $starting;
    $bet                        = produce_contract($bet_params);

    $expected_reasons = [qr/Daily duration.*outside.*range/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '181d';
    $bet = produce_contract($bet_params);

    ok($bet->is_valid_to_buy, '..but when we pick a shorter duration, validates just fine.');

    $bet_params->{date_start}   = Date::Utility->new('2013-03-26 22:01:34')->epoch;
    $bet_params->{duration}     = '3d';
    $bet_params->{date_pricing} = $bet_params->{date_start};
    $bet_params->{barrier}      = 'S10P';
    $bet                        = produce_contract($bet_params);

    $expected_reasons = [qr/buying suspended between NY1600 and GMT0000/];
    test_error_list('buy', $bet, $expected_reasons);

    $underlying = BOM::Market::Underlying->new('GDAXI');

    $bet_params->{underlying}   = $underlying;
    $bet_params->{duration}     = '11d';
    $bet_params->{date_start}   = $underlying->exchange->opening_on(Date::Utility->new('24-Dec-12'))->plus_time_interval('15m');
    $bet_params->{date_pricing} = $bet_params->{date_start};
    $bet                        = produce_contract($bet_params);

    $expected_reasons = [qr/trading days.*calendar days/, qr/holiday blackout period/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{date_start}   = $underlying->exchange->opening_on(Date::Utility->new('6-Dec-12'))->plus_time_interval('15m');
    $bet_params->{date_pricing} = $bet_params->{date_start};
    $bet                        = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we pick an earlier start date, validates just fine.');

    $bet_params->{bet_type} = 'CALL';
    $bet_params->{duration} = '1d';
    $bet                    = produce_contract($bet_params);
    $expected_reasons       = [qr/Daily duration.*outside acceptable range/];
    test_error_list('buy', $bet, $expected_reasons);

    $bet_params->{duration} = '14d';
    $bet = produce_contract($bet_params);
    ok($bet->is_valid_to_buy, '..but when we pick a reasonable duration, validates just fine.');

    my $volsurface = BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'GDAXI',
            recorded_date => Date::Utility->new('2013-03-28 06:00:34'),
        });

    $bet_params->{date_start}   = $underlying->exchange->opening_on(Date::Utility->new('28-Mar-13'))->plus_time_interval('15m');
    $bet_params->{date_pricing} = $bet_params->{date_start};
    $bet_params->{duration}     = '8d';
    $bet_params->{barrier}      = 'S1P';
    $bet                        = produce_contract($bet_params);

    $expected_reasons = [qr/enough trading.*calendar days/];
    test_error_list('buy', $bet, $expected_reasons);
};

subtest 'missing ticks check' => sub {
    plan tests => 2;
    my $underlying = BOM::Market::Underlying->new('frxUSDJPY');
    my $starting   = $oft_used_date->epoch;

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch => $starting,
        quote => 100.012,
        bid   => 100.015,
        ask   => 100.021
    });
    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'INTRADD',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting,
        duration     => '30m',
        barrier      => 'S0P',
        current_tick => $tick,
    };
    my $bet              = produce_contract($bet_params);
    my $expected_reasons = [qr/Missing settlement/];
    test_error_list('sell', $bet, $expected_reasons);
    ok(!$bet->initialized_correctly, 'Considering the errors, we can not settle without intervention.');
};

subtest 'underlying with critical corporate actions' => sub {
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'currency',
        {
            symbol => 'GBP',
            date   => Date::Utility->new,
        });
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'index',
        {
            symbol => 'FPFP',
            date   => Date::Utility->new,
        });
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'FPFP',
            recorded_date => Date::Utility->new,
        });

    my $orig = BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions([]);
    my $underlying = BOM::Market::Underlying->new('FPFP');
    my $starting   = $underlying->exchange->opening_on(Date::Utility->new('2013-03-28'))->plus_time_interval('1h');

    my $bet_params = {
        underlying   => $underlying,
        bet_type     => 'INTRADU',
        currency     => 'USD',
        payout       => 100,
        date_start   => $starting->plus_time_interval('5m1s'),
        duration     => '30m',
        barrier      => 'S0P',
        current_tick => $tick,
        date_pricing => $starting,
    };
    my $bet = produce_contract($bet_params);
    ok $bet->confirm_validity, 'can buy stock';
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions(['FPFP']);
    $bet = produce_contract($bet_params);
    my $expected_reasons = [qr/Underlying.*suspended/];
    test_error_list('buy', $bet, $expected_reasons);
    $bet = produce_contract($bet_params);
    test_error_list('sell', $bet, $expected_reasons);
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->disabled_due_to_corporate_actions($orig);
};

subtest '10% barrier check for double barrier contract' => sub {
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'currency',
        {
            symbol => $_,
            date   => Date::Utility->new,
        }) for (qw/GBP USD/);

    my $now = Date::Utility->new('2014-10-08 10:00:00');

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxGBPUSD',
            recorded_date => $now
        });

    my $tick_params = {
        symbol => 'not_checked',
        epoch  => $now->epoch,
        quote  => 100
    };

    my $tick       = BOM::Market::Data::Tick->new($tick_params);
    my $bet_params = {
        underlying   => 'frxGBPUSD',
        bet_type     => 'UPORDOWN',
        currency     => 'USD',
        payout       => 100,
        date_start   => $now,
        date_pricing => $now,
        duration     => '1d',
        high_barrier => '101',
        low_barrier  => '10',
        current_tick => $tick,
    };
    my $c                = produce_contract($bet_params);
    my $expected_reasons = [qr/Lower barrier.*25%/];
    test_error_list('buy', $c, $expected_reasons);
};

subtest 'intraday indices duration test' => sub {
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'index',
        {
            symbol => 'AS51',
            date   => Date::Utility->new,
        });

    my $now = Date::Utility->new('2015-04-08 10:00:00');
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'AS51',
            recorded_date => $now
        });

    my $tick_params = {
        symbol => 'not_checked',
        epoch  => $now->epoch,
        quote  => 100
    };

    for (my $i = 1800; $i > 0; $i -= 5) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            epoch      => $now->epoch - $i,
            underlying => 'AS51',
            quote      => 100.012,
            bid        => 100.015,
            ask        => 100.021
        });
    }
    my $tick   = BOM::Market::Data::Tick->new($tick_params);
    my $params = {
        bet_type     => 'FLASHU',
        underlying   => 'AS51',
        date_start   => $now,
        date_pricing => $now,
        duration     => '15m',
        currency     => 'AUD',
        current_tick => $tick,
        payout       => 100,
        barrier      => 'S0P',
    };
    my $c = produce_contract($params);
    ok $c->is_valid_to_buy, 'valid 15 minutes Flash on AS51';
    $params->{duration} = '14m';
    $c = produce_contract($params);
    my $expected_reasons = [qr/Intraday duration.*not acceptable/];
    test_error_list('buy', $c, $expected_reasons);
    $params->{duration} = '6h';
    $c                  = produce_contract($params);
    $expected_reasons   = [qr/Intraday duration.*not acceptable/];
    test_error_list('buy', $c, $expected_reasons);

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'index',
        {
            symbol => 'FTSE',
            date   => Date::Utility->new,
        });
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'currency',
        {
            symbol => 'GBP',
            date   => Date::Utility->new,
        });
    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'exchange',
        {
            symbol => 'LSE',
            date   => Date::Utility->new,
        });

    BOM::Test::Data::Utility::UnitTestCouchDB::create_doc(
        'volsurface_moneyness',
        {
            symbol        => 'FTSE',
            recorded_date => $now
        });

    $params->{underlying} = 'FTSE';
    $params->{currency}   = 'GBP';
    $params->{duration}   = '15m';
    $c                    = produce_contract($params);
    $expected_reasons = [qr/trying unauthorised/, qr/Intraday duration.*not acceptable/];
    test_error_list('buy', $c, $expected_reasons);
};

subtest 'intraday index missing pricing coefficient' => sub {
    my $now         = Date::Utility->new('2014-10-08 10:00:00');
    my $tick_params = {
        symbol => 'not_checked',
        epoch  => $now->epoch,
        quote  => 100
    };
    my $tick   = BOM::Market::Data::Tick->new($tick_params);
    my $params = {
        bet_type     => 'FLASHU',
        underlying   => 'FTSE',
        date_start   => $now,
        date_pricing => $now,
        duration     => '15m',
        currency     => 'GBP',
        current_tick => $tick,
        payout       => 100,
        barrier      => 'S0P',
    };
    my $mock = Test::MockModule->new('BOM::Product::Contract');
    $mock->mock('pricing_engine_name' => sub { 'BOM::Product::Pricing::Engine::Intraday::Index' });
    my $c = produce_contract($params);
    my $expected_reasons = [qr/Calibration coefficient missing/, qr/trying unauthorised/, qr/duration.*not acceptable/];
    test_error_list('buy', $c, $expected_reasons);
};

subtest 'expiry_daily expiration time' => sub {
    my $now         = Date::Utility->new('2014-10-08 10:00:00');
    my $tick_params = {
        symbol => 'not_checked',
        epoch  => $now->epoch,
        quote  => 100
    };
    my $tick   = BOM::Market::Data::Tick->new($tick_params);
    my $params = {
        bet_type     => 'FLASHU',
        underlying   => 'AS51',
        date_start   => $now,
        date_pricing => $now,
        duration     => '25h',
        currency     => 'AUD',
        current_tick => $tick,
        payout       => 100,
        barrier      => 'S0P',
    };
    my $c = produce_contract($params);
    ok $c->_validate_expiry_date;
    my $err = ($c->_validate_expiry_date)[0]->{message_to_client};
    is $err, 'Contracts on Australian Index with durations under 24 hours must expire on the same trading day.', 'correct message';

};

# Let's not surprise anyone else
ok(BOM::Platform::Runtime->instance->app_config->quants->features->suspend_claim_types($orig_suspended),
    'Switched RANGE bets back on, if they were.');

sub test_error_list {
    my ($which, $bet, $expected) = @_;
    my @expected_reasons = @{$expected};
    my $err_count        = scalar @expected_reasons;
    my $val_method       = 'is_valid_to_' . lc $which;
    subtest $bet->shortcode . ' error confirmation' => sub {
        plan tests => $err_count + 2;

        ok(!$bet->$val_method, 'Not valid for ' . $which);
        my @got_reasons = $bet->all_errors;
        is(scalar @got_reasons, $err_count, '...for ' . $err_count . ' reason(s)');
        foreach my $expected_reason (@expected_reasons) {
            is(scalar(grep { $_->message =~ $expected_reason } @got_reasons), 1, '...one of which is ' . $expected_reason);
        }
    };
}

done_testing;
