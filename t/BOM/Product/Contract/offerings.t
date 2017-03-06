#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Deep;
use Test::Exception;
use YAML::XS qw(LoadFile);

use BOM::Platform::Runtime;
use LandingCompany::Offerings qw(get_offerings_with_filter);

# test wriiten date.
note('Underlying-Contract offerings on 22-Feb-2016');

subtest 'markets' => sub {
    my @expected = (qw(forex commodities stocks indices volidx));
    lives_ok {
        my @markets = get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config, 'market');
        cmp_bag(\@markets, \@expected, 'correct market list');
    }
    'lives through market test';
};

subtest 'submarkets' => sub {
    my @expected = (
        qw(india_otc_stock americas asia_oceania  energy europe_africa otc_index us_otc_stock uk_otc_stock ge_otc_stock major_pairs metals middle_east minor_pairs random_daily random_index smart_fx)
    );
    lives_ok {
        my @submarkets = get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config, 'submarket');
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
            qw(USCAT USGLDSCH USMCDON USMA USBRKSHR USBNG USIBM USALIBA USPEP USEA USJNJ USAMX USPG UKBP UKRIO UKSTAN UKLLOY UKTSCO DEBMW DENOT DESAP DEDBK DEAIR INMARUTI INRIL INTATASTEEL INBHARTIARTL USAAPL USAMZN USCT USFB USGOOG USMSFT USXOM UKBARC UKBATS UKHSBA DEALV DEDAI DESIE )
        ],
        indices => [
            qw( DJI AEX AS51 BFX BSESENSEX30 DFMGI FCHI GDAXI HSI JCI N225 OBX SPC SSMI STI TOP40 ISEQ OTC_AEX OTC_AS51 OTC_BFX OTC_BIST100 OTC_BSESENSEX30 OTC_DJI OTC_FCHI OTC_FTSE OTC_GDAXI OTC_HSI OTC_IXIC OTC_N225 OTC_SPC)
        ],
        volidx => [qw( RDBEAR RDBULL R_100 R_10 R_25 R_50 R_75)],
    );

    lives_ok {
        foreach my $market (get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config, 'market')) {
            if (not $expected{$market}) {
                fail("market [$market] not found");
            } else {
                my @underlying_symbols =
                    get_offerings_with_filter(BOM::Platform::Runtime->instance->get_offerings_config, 'underlying_symbol', {market => $market});
                cmp_bag(\@underlying_symbols, $expected{$market}, 'correct underlying symbol list for [' . $market . ']');
            }
        }
    }
    'lives through underlying symbol test';
};
