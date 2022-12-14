#!/etc/rmg/bin/perl
use strict;
use warnings;

use Test::Most 0.22;
use Test::MockTime qw(set_relative_time);
use YAML::XS       qw(DumpFile LoadFile);

use Finance::Contract::Category;
use BOM::MarketData qw(create_underlying_db);
use BOM::Config::Runtime;

my $udb;
lives_ok {
    $udb = create_underlying_db();
}
'Initialized';

eq_or_diff [sort keys %{Finance::Contract::Category->get_all_contract_categories}],
    [
    sort
        qw(callput endsinout touchnotouch staysinout asian digits vanilla lookback reset runs highlowticks callputspread callputequal multiplier accumulator turbos)
    ],
    "Correct list of all contract categories";

eq_or_diff [sort $udb->available_expiry_types], [sort qw(intraday daily tick no_expiry)], 'Correct list of available expiry types.';

eq_or_diff [sort $udb->available_start_types], [sort qw(spot forward)], 'Correct list of available start types.';

eq_or_diff [sort $udb->markets], [sort qw(commodities forex indices synthetic_index stocks cryptocurrency)], "Correct list of markets";

eq_or_diff [sort $udb->symbols_for_intraday_fx], [
    sort qw(frxAUDCAD frxAUDCHF frxAUDJPY frxAUDNZD frxAUDUSD frxEURAUD frxEURCAD frxEURCHF
        frxEURGBP frxEURJPY frxEURNZD frxEURUSD frxGBPAUD frxGBPCAD frxGBPCHF
        frxGBPJPY frxGBPNZD frxGBPUSD frxNZDUSD frxUSDCAD frxUSDCHF frxUSDJPY frxXAGUSD frxXAUUSD WLDAUD WLDEUR WLDGBP WLDUSD WLDXAU)
    ],
    'Correct list of intraday historical symbols.';

my @ul_indices_on_flash = qw(OTC_AEX OTC_AS51 OTC_DJI OTC_FCHI OTC_FTSE OTC_GDAXI OTC_HSI OTC_IBEX35 OTC_N225 OTC_NDX OTC_SPC OTC_SSMI OTC_SX5E);
cmp_bag [
    sort $udb->get_symbols_for(
        market            => 'indices',
        contract_category => 'callput',
        start_type        => 'spot',
        expiry_type       => 'intraday',
    )
    ],
    \@ul_indices_on_flash,
    "introduced intraday callput on indices";
cmp_bag [
    sort $udb->get_symbols_for(
        market            => 'indices',
        contract_category => 'callput',
        start_type        => 'spot',
        expiry_type       => 'intraday',
    )
    ],
    \@ul_indices_on_flash, "Correct list of flashes for indices on virtual accounts";

my @ul_forex_on_endsinout = qw(
    frxAUDJPY frxAUDUSD frxEURAUD frxEURCAD frxEURCHF frxEURGBP frxEURJPY  frxEURUSD
    frxGBPAUD frxGBPJPY frxGBPUSD frxUSDCAD frxUSDCHF frxUSDJPY);

eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'forex',
        contract_category => 'endsinout',
    )
    ],
    \@ul_forex_on_endsinout, "Correct list of endsinout for forex on real accounts";
eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'forex',
        contract_category => 'endsinout',
    )
    ],
    \@ul_forex_on_endsinout, "Correct list of endsinout for forex on virtual accounts";

my @ul_indices_on_endsinout = qw(
    OTC_AEX OTC_AS51 OTC_DJI OTC_FCHI OTC_FTSE OTC_GDAXI OTC_HSI OTC_IBEX35 OTC_N225 OTC_NDX OTC_SPC OTC_SSMI OTC_SX5E
);
eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'indices',
        contract_category => 'endsinout',
    )
    ],
    \@ul_indices_on_endsinout, "Correct list of endsinout for indices on real accounts";

eq_or_diff [
    sort $udb->get_symbols_for(
        market            => ['indices', 'forex',],
        contract_category => 'endsinout',
    )
    ],
    [sort @ul_forex_on_endsinout, @ul_indices_on_endsinout],
    "Correct list of endsinout for forex+indices on real accounts";

my @ul_forex_active = sort qw(
    frxAUDJPY frxAUDUSD frxEURAUD frxEURCAD frxEURCHF frxEURGBP frxEURJPY
    frxEURUSD frxGBPAUD frxGBPCAD frxGBPCHF frxGBPJPY frxGBPNOK frxGBPPLN
    frxGBPUSD frxNZDUSD frxUSDCAD frxUSDCHF frxUSDJPY frxUSDNOK
    frxUSDSEK frxEURNZD frxGBPNZD frxAUDCHF frxAUDCAD frxAUDNZD
    frxNZDJPY frxUSDMXN frxUSDPLN);
eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'forex',
        contract_category => 'ANY'
    )
    ],
    \@ul_forex_active, "Correct list of active symbols for forex";

my @ul_basket_index_active = sort qw(
    WLDAUD    WLDEUR    WLDGBP    WLDUSD WLDXAU);
eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'synthetic_index',
        submarket         => ['forex_basket', 'commodity_basket'],
        contract_category => 'ANY'
    )
    ],
    \@ul_basket_index_active, "Correct list of active symbols for basket_index";

my @ul_commodities_active = qw( frxBROUSD frxXAGUSD frxXAUUSD frxXPDUSD frxXPTUSD);
eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'commodities',
        contract_category => 'ANY'
    )
    ],
    \@ul_commodities_active, "Correct list for commodities";

throws_ok { $udb->get_symbols_for(contract_category => 'IV'); } qr/market is not specified/, 'Could not get underlyings if market is not specified';

subtest "sub market related" => sub {
    my @ul_random_daily = qw( RDBEAR RDBULL );
    eq_or_diff [
        sort $udb->get_symbols_for(
            market            => 'synthetic_index',
            submarket         => 'random_daily',
            contract_category => 'ANY',
        )
        ],
        \@ul_random_daily, "Correct list of active symbols for random_daily sub market";

    my @ul_random = qw(1HZ100V 1HZ10V 1HZ200V 1HZ25V 1HZ300V 1HZ50V 1HZ75V R_10 R_100 R_25 R_50 R_75);
    eq_or_diff [
        sort $udb->get_symbols_for(
            market            => 'synthetic_index',
            submarket         => 'random_index',
            contract_category => 'ANY',
        )
        ],
        \@ul_random, "Correct list of active symbols for random_index sub market";

    my @empty;
    eq_or_diff [
        sort $udb->get_symbols_for(
            market    => 'forex',
            submarket => 'invalid',
        )
        ],
        \@empty, "no matching sub market";

    eq_or_diff [
        sort $udb->get_symbols_for(
            market    => 'synthetic_index',
            submarket => 'invalid',
        )
        ],
        \@empty, "no matching sub market";

    my @ul_indices = qw(OTC_DJI OTC_NDX OTC_SPC);
    eq_or_diff [
        sort $udb->get_symbols_for(
            market            => 'indices',
            contract_category => 'endsinout',
            submarket         => 'americas_OTC',
        )
        ],
        \@ul_indices, "Correct list of endsinout for indices on VRTC accounts, for sub market americas";

    my @ul_commodities = qw( frxBROUSD frxXAGUSD frxXAUUSD frxXPDUSD frxXPTUSD);
    eq_or_diff [
        sort $udb->get_symbols_for(
            market            => 'commodities',
            contract_category => 'ANY',
            submarket         => 'ANY',
        )
        ],
        \@ul_commodities, "Correct list for commodities, for sub market ANY";
};

subtest 'including disabled' => sub {
    my $orig_buy = BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_buy;
    BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_buy(['frxUSDJPY']);
    ok(
        scalar grep { $_ eq 'frxUSDJPY' } (
            $udb->get_symbols_for(
                market            => 'forex',
                contract_category => 'endsinout',
            )
        ),
        "USD/JPY returned for when unfiltered for disabled."
    );
    ok(
        not scalar grep { $_ eq 'frxUSDJPY' } (
            $udb->get_symbols_for(
                market            => 'forex',
                contract_category => 'endsinout',
                exclude_suspended => 1,
            )
        ),
        0,
        "USD/JPY is not returned for when unfiltered for disabled."
    );
    BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_buy($orig_buy);
};

subtest 'testing with suspend_trades' => sub {
    my $orig_buy = BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_trades;
    BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_trades(['frxXAUUSD']);

    my @symbols = $udb->symbols_for_intraday_fx(0);

    ok(scalar grep { $_ eq 'frxXAUUSD' } @symbols, "XAUUSD returned");

    BOM::Config::Runtime->instance->app_config->quants->underlyings->suspend_trades($orig_buy);
};

done_testing;
