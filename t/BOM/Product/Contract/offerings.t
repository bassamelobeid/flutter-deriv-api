#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 5;
use Test::Deep;
use Test::Exception;
use Test::NoWarnings;
use YAML::XS qw(LoadFile);

use BOM::Market::Underlying;
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::System::Chronicle;

# test wriiten date.
note('Underlying-Contract offerings on 22-Feb-2016');

subtest 'markets' => sub {
    my @expected = (qw(forex commodities stocks indices volidx));
    lives_ok {
        my @markets = get_offerings_with_filter('market');
        cmp_bag(\@markets, \@expected, 'correct market list');
    }
    'lives through market test';
};

subtest 'submarkets' => sub {
    my @expected = (
        qw(americas amsterdam asia_oceania belgium energy europe_africa otc_index otc_stock france major_pairs metals middle_east minor_pairs random_daily random_index smart_fx)
    );
    lives_ok {
        my @submarkets = get_offerings_with_filter('submarket');
        cmp_bag(\@submarkets, \@expected, 'correct submarket list');
    }
    'lives_through submarket test';
};

subtest 'underlying symbols' => sub {
    my %expected = (
        forex => [
            qw( WLDAUD WLDEUR WLDGBP WLDUSD frxAUDCAD frxAUDCHF frxAUDJPY frxAUDNZD frxAUDPLN frxAUDUSD frxEURAUD frxEURCAD frxEURCHF frxEURGBP frxEURJPY frxEURNZD frxEURUSD frxGBPAUD frxGBPCAD frxGBPCHF frxGBPJPY frxGBPNOK frxGBPNZD frxGBPPLN frxGBPUSD frxNZDJPY frxNZDUSD frxUSDCAD frxUSDCHF frxUSDJPY frxUSDMXN frxUSDNOK frxUSDPLN frxUSDSEK)
        ],
        commodities => [qw( frxBROUSD frxXAGUSD frxXAUUSD frxXPDUSD frxXPTUSD)],
        stocks      => [
            qw( USAAPL USAMZN USCT USFB USGE USGOOG USKO USMSFT USPFE USXOM USBARC UKBATS UKGSK UKHSBA USVOD DEALV DEBAYER DEDAI DESIE DEVOWGEN AUANZ AUBHP AUCBA AUMQG AUQAN BBABI BBBELG BBGBLB BBKBC BBUCB FPACA FPAI FPAIR FPBN FPBNP FPCA FPCS FPDG FPEDF FPEI FPFP FPGLE FPGSZ FPKER FPMC FPOR FPORA FPRI FPRNO FPSAF FPSAN FPSGO FPSU FPVIV NAASML NAHEIA NAINGA NARDSA NAUNA)
        ],
        indices => [qw( AEX AS51 BFX BSESENSEX30 DFMGI DJI FCHI GDAXI HSI JCI N225 OBX SPC SSMI STI TOP40 ISEQ OTC_AEX OTC_AS51 OTC_BFX OTC_BIST100 OTC_BSESENSEX30 OTC_DJI OTC_FCHI OTC_FTSE OTC_GDAXI OTC_HSI OTC_IXIC OTC_N225 OTC_SPC )],
        volidx  => [qw( RDBEAR RDBULL R_100 R_25 R_50 R_75)],
    );

    lives_ok {
        foreach my $market (get_offerings_with_filter('market')) {
            if (not $expected{$market}) {
                fail("market [$market] not found");
            } else {
                my @underlying_symbols = get_offerings_with_filter('underlying_symbol', {market => $market});
                cmp_bag(\@underlying_symbols, $expected{$market}, 'correct underlying symbol list for [' . $market . ']');
            }
        }
    }
    'lives through underlying symbol test';
};

subtest 'contract offerings' => sub {
    my $expected = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Contract/offerings_test.yml');
    lives_ok {
        foreach my $underlying_symbol (get_offerings_with_filter('underlying_symbol')) {
            if (not $expected->{$underlying_symbol}) {
                fail("underlying symbol [$underlying_symbol] not found");
            } else {
                is_deeply(
                    BOM::Market::Underlying->new($underlying_symbol)->contracts,
                    $expected->{$underlying_symbol},
                    'correct contract offerings for ' . $underlying_symbol
                );
            }
        }
    }
    'lives through contract offerings';
};
