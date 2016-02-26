#!/usr/bin/env perl

use strict;
use warnings;

use Test::Most (tests => 1);
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use BOM::Test::Runtime qw(:normal);
use BOM::Product::ContractFactory qw( simple_contract_info );
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

subtest 'Proper form' => sub {
    my @shortcodes = (
        qw~
            CALL_R_50_100_1393816285_6_MAR_14_7582422_0
            CALL_RDBULL_100_1393816299_1393828299_S0P_0
            ONETOUCH_FRXAUDJPY_100_1394502374_1394509574_S133P_0
            CALL_FRXEURUSD_100_1394502338_1394509538_S0P_0
            CALL_FRXEURUSD_100_1394502112_1394512912_S0P_0
            FLASHU_FRXNZDUSD_100_1394502169_1394512969_S0P_0
            FLASHD_FRXUSDJPY_100_1394502298_1394513098_S0P_0
            FLASHU_FRXNZDUSD_100_1394502392_1394509592_S0P_0
            INTRADU_FRXEURNOK_100_1394503200_1394514000_S0P_0
            INTRADD_FRXEURNOK_100_1394502900_1394513700_S0P_0
            FLASHU_FRXUSDJPY_100_1394501981_1394573981_S0P_0
            ONETOUCH_FRXAUDJPY_100_1394502043_1394538043_S300P_0
            FLASHD_FRXEURNOK_100_1394590423_1394591143_S0P_0
            PUT_FRXUSDJPY_100_1393816315_19_SEP_14_1014530_0
            CALL_FRXXAUUSD_100_1393816326_19_SEP_14_13431500_0
            DOUBLEUP_INICICIBC_100_1393822979_19_SEP_14_S0P_0
            DOUBLEUP_FRXUSDJPY_100_1394501971_31_MAR_14_S0P_0
            ONETOUCH_FRXAUDJPY_100_1394502053_21_MAR_14_947100_0
            CALL_FRXEURUSD_100_1394502104_14_MAR_14_13870_0
            DOUBLEDOWN_FRXNZDUSD_100_1394502179_14_MAR_14_S0P_0
            DOUBLEDOWN_FRXEURNOK_100_1394502244_14_MAR_14_S0P_0
            DOUBLEUP_FRXUSDJPY_100_1394502289_14_MAR_14_S0P_0
            CALL_FRXEURUSD_100_1394502345_9_JUL_14_13871_0
            NOTOUCH_FRXAUDJPY_100_1394502360_9_JUL_14_979900_0
            DOUBLEDOWN_FRXNZDUSD_100_1394502401_9_JUL_14_S0P_0
            DOUBLEUP_FRXEURNOK_100_1394502431_14_MAR_14_S0P_0
            RANGE_AS51_100_1394590984_19_MAR_14_5436_5280
            RANGE_FRXAUDJPY_100_1394591024_20_MAR_14_931040_910000
            ~
    );
    my @currencies = ('USD', 'EUR', 'RUR');    # Inexhaustive, incorrect list: just to be sure the currency is not accidentally hard-coded.
    plan tests => 2 * scalar @shortcodes * scalar @currencies;

    foreach my $currency (@currencies) {
        my $expected_standard_form = qr/$currency (?:\d*\.?\d+) payout if .*\.$/;    # Simplified standard form to which all should adhere.
                                                                                     # Can this be improved further?
        my $params;
        foreach my $shortcode (@shortcodes) {
            my ($description) = simple_contract_info($shortcode, $currency);
            my ($again)       = simple_contract_info($shortcode, $currency);
            like($description, $expected_standard_form, $shortcode . ' => long code form appears ok');
            cmp_ok $again, 'eq', $description, '... and second invocation returns the same result';
        }
    }
};

1;
