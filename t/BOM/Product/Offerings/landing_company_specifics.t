#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::Deep;
use Test::Exception;
use Test::NoWarnings;

use BOM::Product::Offerings qw(get_offerings_flyby get_offerings_with_filter);

my @expected_lc   = qw(japan-virtual fog costarica maltainvest japan malta iom);
my %expected_type = (
    'japan-virtual' => ['CALLE', 'NOTOUCH', 'ONETOUCH', 'PUT', 'RANGE', 'UPORDOWN', 'EXPIRYRANGEE', 'EXPIRYMISS'],
    fog             => [
        'ASIAND',   'ASIANU',    'CALL',       'DIGITDIFF',  'DIGITEVEN',   'DIGITMATCH',
        'DIGITODD', 'DIGITOVER', 'DIGITUNDER', 'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH',
        'ONETOUCH', 'PUT',       'RANGE',      'SPREADD',    'SPREADU',     'UPORDOWN',
    ],
    costarica => [
        'ASIAND',   'ASIANU',    'CALL',       'DIGITDIFF',  'DIGITEVEN',   'DIGITMATCH',
        'DIGITODD', 'DIGITOVER', 'DIGITUNDER', 'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH',
        'ONETOUCH', 'PUT',       'RANGE',      'SPREADD',    'SPREADU',     'UPORDOWN'
    ],
    maltainvest => ['CALL',  'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH', 'ONETOUCH', 'PUT',      'RANGE',        'UPORDOWN'],
    japan       => ['CALLE', 'NOTOUCH',    'ONETOUCH',    'PUT',    'RANGE',    'UPORDOWN', 'EXPIRYRANGEE', 'EXPIRYMISS'],
    malta       => [
        'ASIAND',   'ASIANU',    'CALL',       'DIGITDIFF',  'DIGITEVEN',   'DIGITMATCH',
        'DIGITODD', 'DIGITOVER', 'DIGITUNDER', 'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH',
        'ONETOUCH', 'PUT',       'RANGE',      'SPREADD',    'SPREADU',     'UPORDOWN'
    ],
    iom => [
        'ASIAND',   'ASIANU',    'CALL',       'DIGITDIFF',  'DIGITEVEN',   'DIGITMATCH',
        'DIGITODD', 'DIGITOVER', 'DIGITUNDER', 'EXPIRYMISS', 'EXPIRYRANGE', 'NOTOUCH',
        'ONETOUCH', 'PUT',       'RANGE',      'SPREADD',    'SPREADU',     'UPORDOWN'
    ],

);
my %expected_market = (
    'japan-virtual' => ['forex'],
    japan           => ['forex'],
    fog             => ['commodities', 'forex', 'indices', 'volidx', 'stocks'],
    costarica       => ['commodities', 'forex', 'indices', 'volidx', 'stocks'],
    maltainvest => ['commodities', 'forex', 'indices', 'stocks'],
    malta       => ['volidx'],
    iom => ['commodities', 'forex', 'indices', 'volidx', 'stocks'],
);
subtest 'landing_company specifics' => sub {
    lives_ok {
        foreach my $lc (@expected_lc) {
            my $fb = get_offerings_flyby($lc);
            my @market_lc = $fb->values_for_key('market');
            cmp_bag(\@market_lc, $expected_market{$lc}, 'market list for ' . $lc);
        }
    }
    'market list by landing company';

    lives_ok {
        foreach my $lc (@expected_lc) {
            my $fb = get_offerings_flyby($lc);
            my @type_lc = $fb->values_for_key('contract_type');
            cmp_bag(\@type_lc, $expected_type{$lc}, 'contract type list for ' . $lc);
        }
    }
};

subtest 'offerings check' => sub {
    my %test = (
        japan => {
            'commodities' => 0,
            'forex'       => 1,
            'indices'     => 0,
            'volidx',     => 0,
            'stocks'      => 0
        },
        'japan-virtual' => {
            'commodities' => 0,
            'forex'       => 1,
            'indices'     => 0,
            'volidx',     => 0,
            'stocks'      => 0
        },
        malta => {
            'commodities' => 0,
            'forex'       => 0,
            'indices'     => 0,
            'volidx',     => 1,
            'stocks'      => 0
        },
        maltainvest => {
            'commodities' => 1,
            'forex'       => 1,
            'indices'     => 1,
            'volidx',     => 0,
            'stocks'      => 1
        },
        fog => {
            'commodities' => 1,
            'forex'       => 1,
            'indices'     => 1,
            'volidx',     => 1,
            'stocks'      => 1
        },
        iom => {
            'commodities' => 1,
            'forex'       => 1,
            'indices'     => 1,
            'volidx',     => 1,
            'stocks'      => 1
        },
    );
    foreach my $testname (keys %test) {
        my $fb = get_offerings_flyby($testname);
        my $result = $test{$testname};
        foreach my $market (keys %$result) {
            if ($result->{$market}) {
                ok $fb->query({
                    market          => $market
                });
            } else {
                ok !$fb->query({
                    market          => $market
                });
            }
        }
    }
};

subtest 'legal allowed underlyings' => sub {
    my @random     = qw(R_75 RDBEAR RDBULL R_25 R_100 R_50);
    my @non_random = qw(
        USAAPL
        USAMZN
        USCT
        USFB
        USGOOG
        USMSFT
        USXOM
        UKBARC
        UKBATS
        UKHSBA
        DEALV
        DEDAI
        DESIE
        USCAT
        USGLDSCH 
        USMCDON 
        USMA
        USBRKSHR
        USBNG 
        USIBM 
        USALIBA 
        USPEP 
        USEA 
        USJNJ 
        USAMX 
        USPG 
        UKBP 
        UKRIO 
        UKSTAN 
        UKLLOY 
        UKTSCO 
        DEBMW 
        DENOT 
        DESAP 
        DEDBK 
        DEAIR  
        INMARUTI 
        INRIL 
        INTATAMOTORS 
        INTATASTEEL 
        INBHARTIARTL
        OTC_IXIC
        OTC_BSESENSEX30
        OTC_BIST100
        OTC_AEX
        OTC_AS51
        OTC_FTSE
        OTC_BFX
        OTC_DJI
        OTC_FCHI
        OTC_GDAXI
        OTC_HSI
        OTC_N225
        OTC_SPC
        frxAUDJPY
        frxUSDJPY
        frxAUDCAD
        TOP40
        WLDUSD
        frxAUDPLN
        GDAXI
        STI
        frxAUDNZD
        frxEURNZD
        frxUSDCAD
        OBX
        JCI
        frxEURAUD
        frxGBPJPY
        frxEURCHF
        frxEURJPY
        frxXPDUSD
        frxGBPUSD
        WLDGBP
        DJI
	FCHI
        frxGBPNZD
        frxXAGUSD
        frxAUDCHF
        frxUSDPLN
        frxUSDCHF
        frxNZDJPY
        frxGBPCAD
        frxBROUSD
        SPC
        WLDEUR
        N225
        frxXPTUSD
        DFMGI
        frxUSDNOK
        frxEURCAD
        SSMI
        frxGBPNOK
        frxXAUUSD
        BFX
        frxGBPPLN
        frxGBPAUD
        frxUSDSEK
        ISEQ
        HSI
        frxUSDMXN
        frxAUDUSD
        frxGBPCHF
        AS51
        frxEURUSD
        frxEURGBP
        BSESENSEX30
        WLDAUD
        frxNZDUSD
        AEX
    );
    my %expected_list = (
        japan           => [qw(frxAUDJPY frxAUDUSD frxEURGBP frxEURJPY frxEURUSD frxGBPJPY frxGBPUSD frxUSDCAD frxUSDJPY)],
        'japan-virtual' => [qw(frxAUDJPY frxAUDUSD frxEURGBP frxEURJPY frxEURUSD frxGBPJPY frxGBPUSD frxUSDCAD frxUSDJPY)],
        malta           => [@random],
        maltainvest     => [@non_random],
        iom             => [@random, @non_random],
        costarica       => [@random, @non_random],
    );

    foreach my $lc (keys %expected_list) {
        my @got = get_offerings_with_filter('underlying_symbol', {landing_company => $lc});
        cmp_bag(\@got, $expected_list{$lc}, 'underlying list for ' . $lc);
    }
};
