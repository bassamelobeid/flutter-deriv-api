#!/usr/bin/perl

use strict;
use warnings;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Product::ContractFactory qw(produce_contract);

use Date::Utility;
use Test::More;
use Test::FailWarnings;
use JSON::MaybeXS;

my $json = JSON::MaybeXS->new;

# TODO move to cpp-pricing
# shortcode implementation is in Finance::Contract.
# Tried writing test in Finance::Contract, but the class acts just as a base class
# with limited method implementation.
subtest 'shortcodes' => sub {
    # fixed time because we need to compare shortcode outputs
    my $now  = Date::Utility->new('2018-07-10')->epoch;
    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        underlying => 'frxUSDJPY',
        epoch      => $now,
        quote      => 101
    });

    my $sb_args = {
        bet_type     => 'CALL',
        underlying   => 'frxUSDJPY',
        date_start   => $now,
        date_pricing => $now,
        barrier      => 'S0P',
        payout       => 100,
        currency     => 'USD',
        current_tick => $tick,
    };
    my $db_args = {
        bet_type     => 'EXPIRYMISS',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        payout       => 100,
        currency     => 'USD',
        high_barrier => 'S105P',
        low_barrier  => 'S-210P',
        current_tick => $tick,
    };

    my @test_cases = (
        [{%$sb_args, duration => '5t'}, 'CALL_FRXUSDJPY_100_1531180800_5T_S0P_0', 'CALL_FRXUSDJPY_USD100_1531180800_5T_S0P_0'],    # 5 ticks ATM CALL
        [{
                %$sb_args,
                duration => '5d',
                barrier  => 100.01
            },
            'CALL_FRXUSDJPY_100_1531180800_1531699199_100010000_0',
            'CALL_FRXUSDJPY_USD100_1531180800_1531699199_100010000_0'
        ],    # 5 days non ATM CALL
        [{%$sb_args, duration => '5m'}, 'CALL_FRXUSDJPY_100_1531180800_1531181100_S0P_0', 'CALL_FRXUSDJPY_USD100_1531180800_1531181100_S0P_0']
        ,     # 5 minutes ATM CALL
        [{
                %$sb_args,
                duration     => '5m',
                date_pricing => $now - 300
            },
            'CALL_FRXUSDJPY_100_1531180800F_1531181100_S0P_0',
            'CALL_FRXUSDJPY_USD100_1531180800F_1531181100_S0P_0'
        ],    # 5 minutes ATM forward starting CALL
        [{
                %$sb_args,
                duration     => '5m',
                date_pricing => $now - 300,
                fixed_expiry => 1
            },
            'CALL_FRXUSDJPY_100_1531180800F_1531181100F_S0P_0',
            'CALL_FRXUSDJPY_USD100_1531180800F_1531181100F_S0P_0'
        ],    # 5 minutes ATM forward starting CALL
        [{
                %$sb_args,
                fixed_expiry => 1,
                date_expiry  => '2018-07-11 23:59:59'
            },
            'CALL_FRXUSDJPY_100_1531180800_1531353599F_S0P_0',
            'CALL_FRXUSDJPY_USD100_1531180800_1531353599F_S0P_0'
        ],    # 1 day fixed expiry ATM CALL
        [{%$db_args, duration => '5t'}, 'EXPIRYMISS_R_100_100_1531180800_5T_S105P_S-210P', 'EXPIRYMISS_R_100_USD100_1531180800_5T_S105P_S-210P']
        ,     # 5 ticks ATM EXPIRYMISS
        [{
                %$db_args,
                duration     => '5d',
                high_barrier => 101.01,
                low_barrier  => 98.02
            },
            'EXPIRYMISS_R_100_100_1531180800_1531699199_101010000_98020000',
            'EXPIRYMISS_R_100_USD100_1531180800_1531699199_101010000_98020000'
        ],    # 5 days non ATM EXPIRYMISS
        [
            {%$db_args, duration => '5m'}, 'EXPIRYMISS_R_100_100_1531180800_1531181100_S105P_S-210P',
            'EXPIRYMISS_R_100_USD100_1531180800_1531181100_S105P_S-210P'
        ],    # 5 minutes ATM EXPIRYMISS
        [{
                %$db_args,
                duration     => '5m',
                date_pricing => $now - 300
            },
            'EXPIRYMISS_R_100_100_1531180800_1531181100_S105P_S-210P',
            'EXPIRYMISS_R_100_USD100_1531180800_1531181100_S105P_S-210P'
        ],    # 5 minutes ATM forward starting EXPIRYMISS
        [{
                %$db_args,
                duration     => '5m',
                date_pricing => $now - 300,
                fixed_expiry => 1
            },
            'EXPIRYMISS_R_100_100_1531180800_1531181100F_S105P_S-210P',
            'EXPIRYMISS_R_100_USD100_1531180800_1531181100F_S105P_S-210P'
        ],    # 5 minutes ATM forward starting EXPIRYMISS
        [{
                %$db_args,
                fixed_expiry => 1,
                date_expiry  => '2018-07-11 23:59:59'
            },
            'EXPIRYMISS_R_100_100_1531180800_1531353599F_S105P_S-210P',
            'EXPIRYMISS_R_100_USD100_1531180800_1531353599F_S105P_S-210P'
        ],    # 1 day fixed expiry ATM EXPIRYMISS
    );

    foreach my $test (@test_cases) {
        my ($args, $expected_shortcode, $expected_shortcode_w_curr) = @$test;
        my $c = produce_contract($args);
        delete $args->{current_tick};
        note('input: ' . $json->encode($args));
        is $c->shortcode, $expected_shortcode, 'compare shortcode for input';
        is $c->shortcode(1), $expected_shortcode_w_curr, 'compare shortcode with currency for input';
    }

};

done_testing();
