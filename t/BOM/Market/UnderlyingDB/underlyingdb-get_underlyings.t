#!/usr/bin/env perl
use strict;
use warnings;

use Test::Most 0.22;
use Test::MockTime qw(set_relative_time);
require Test::NoWarnings;
use YAML::XS qw(DumpFile LoadFile);

use BOM::Market::UnderlyingDB;

my $udb;
lives_ok {
    $udb = BOM::Market::UnderlyingDB->instance();
}
'Initialized';

eq_or_diff [sort $udb->available_contract_categories], [sort qw(callput endsinout touchnotouch spreads staysinout asian digits)],
    "Correct list of available contract categories";

eq_or_diff [sort $udb->available_expiry_types], [sort qw(intraday daily tick)], 'Correct list of available expiry types.';

eq_or_diff [sort $udb->available_start_types], [sort qw(spot forward)], 'Correct list of available start types.';

eq_or_diff [sort $udb->markets], [sort qw(commodities forex indices random stocks)], "Correct list of markets";

eq_or_diff [sort $udb->symbols_for_intraday_fx], [
    sort qw(frxAUDCAD frxAUDCHF frxAUDJPY frxAUDNZD frxAUDPLN frxAUDUSD frxEURAUD frxEURCAD frxEURCHF
        frxEURGBP frxEURJPY frxEURNZD frxEURUSD frxGBPAUD frxGBPCAD frxGBPCHF
        frxGBPJPY frxGBPNZD frxGBPUSD frxNZDUSD frxUSDCAD frxUSDCHF frxUSDJPY frxXAGUSD frxXAUUSD WLDAUD WLDEUR WLDGBP WLDUSD)
    ],
    'Correct list of intraday historical symbols.';

my @ul_indices_on_flash = qw(AEX AS51 BFX FCHI GDAXI HSI SSMI STI);
cmp_bag [
    sort $udb->get_symbols_for(
        market            => 'indices',
        contract_category => 'callput',
        start_type        => 'spot',
        expiry_type       => 'intraday',
        broker            => 'CR',
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
        broker            => 'VRTC',
    )
    ],
    \@ul_indices_on_flash, "Correct list of flashes for indices on virtual accounts";

my @ul_forex_on_endsinout = qw(
    frxAUDJPY frxAUDUSD frxEURAUD frxEURCAD frxEURCHF frxEURGBP frxEURJPY  frxEURUSD
    frxGBPAUD frxGBPCAD frxGBPJPY frxGBPUSD frxNZDUSD frxUSDCAD frxUSDCHF frxUSDJPY);

eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'forex',
        contract_category => 'endsinout',
        broker            => 'MLT',
    )
    ],
    \@ul_forex_on_endsinout, "Correct list of endsinout for forex on real accounts";
eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'forex',
        contract_category => 'endsinout',
        broker            => 'VRTC',
    )
    ],
    \@ul_forex_on_endsinout, "Correct list of endsinout for forex on virtual accounts";

my @ul_indices_on_endsinout = qw(
    AEX AS51 DJI FCHI GDAXI HSI N225  SPC SSMI
);
eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'indices',
        contract_category => 'endsinout',
        broker            => 'VRTC',
    )
    ],
    \@ul_indices_on_endsinout, "Correct list of endsinout for indices on real accounts";

eq_or_diff [
    sort $udb->get_symbols_for(
        market            => ['indices', 'forex',],
        contract_category => 'endsinout',
        broker            => 'VRTC',
    )
    ],
    [sort @ul_forex_on_endsinout, @ul_indices_on_endsinout],
    "Correct list of endsinout for forex+indices on real accounts";

my @ul_forex_active = sort qw(
    WLDAUD    WLDEUR    WLDGBP    WLDUSD
    frxAUDJPY frxAUDUSD frxEURAUD frxEURCAD frxEURCHF frxEURGBP frxEURJPY
    frxEURUSD frxGBPAUD frxGBPCAD frxGBPCHF frxGBPJPY frxGBPNOK frxGBPPLN
    frxGBPUSD frxNZDUSD frxUSDCAD frxUSDCHF frxUSDJPY frxUSDNOK
    frxUSDSEK frxEURNZD frxGBPNZD frxAUDCHF frxAUDCAD frxAUDNZD frxAUDPLN
    frxNZDJPY frxUSDMXN frxUSDPLN);
eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'forex',
        contract_category => 'ANY'
    )
    ],
    \@ul_forex_active, "Correct list of active symbols for forex";

my @ul_commodities_active = qw( frxBROUSD frxXAGUSD frxXAUUSD frxXPDUSD frxXPTUSD);
eq_or_diff [
    sort $udb->get_symbols_for(
        market            => 'commodities',
        contract_category => 'ANY'
    )
    ],
    \@ul_commodities_active, "Correct list for commodities";

throws_ok { $udb->get_symbols_for(contract_category => 'IV', broker => 'VRTC',); } qr/market is not specified/,
    'Could not get underlyings if market is not specified';

subtest "sub market related" => sub {
    my @ul_random_daily = qw( RDBEAR RDBULL RDMOON RDSUN );
    eq_or_diff [
        sort $udb->get_symbols_for(
            market            => 'random',
            submarket         => 'random_daily',
            contract_category => 'ANY',
        )
        ],
        \@ul_random_daily, "Correct list of active symbols for random_daily sub market";
    my @ul_random_nightly = qw( RDMARS RDVENUS RDYANG RDYIN );
    eq_or_diff [
        sort $udb->get_symbols_for(
            market            => 'random',
            submarket         => 'random_nightly',
            contract_category => 'ANY',
        )
        ],
        \@ul_random_nightly, "Correct list of active symbols for random_nightly sub market";

    my @ul_random = qw( R_100 R_25 R_50 R_75 );
    eq_or_diff [
        sort $udb->get_symbols_for(
            market            => 'random',
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
            market    => 'random',
            submarket => 'invalid',
        )
        ],
        \@empty, "no matching sub market";

    my @ul_indices = qw( DJI SPC);
    eq_or_diff [
        sort $udb->get_symbols_for(
            market            => 'indices',
            contract_category => 'endsinout',
            broker            => 'VRTC',
            submarket         => 'americas',
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
    my $orig_buy = BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy;
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy(['frxUSDJPY']);
    ok(
        scalar grep { $_ eq 'frxUSDJPY' } (
            $udb->get_symbols_for(
                market            => 'forex',
                contract_category => 'endsinout',
                broker            => 'VRTC',
            )
        ),
        "USD/JPY returned for when unfiltered for disabled."
    );
    ok(
        not scalar grep { $_ eq 'frxUSDJPY' } (
            $udb->get_symbols_for(
                market            => 'forex',
                contract_category => 'endsinout',
                broker            => 'VRTC',
                exclude_disabled  => 1,
            )
        ),
        0,
        "USD/JPY is not returned for when unfiltered for disabled."
    );
    BOM::Platform::Runtime->instance->app_config->quants->underlyings->suspend_buy($orig_buy);
};

Test::NoWarnings::had_no_warnings();
done_testing;
