#!/usr/bin/perl

use Test::More tests => 7;
use Test::NoWarnings;
use Test::Exception;

use Scalar::Util qw(looks_like_number);
use BOM::Product::Pricing::Engine::Slope;
use Date::Utility;

my $now = Date::Utility->new();
# Hard-coded market_data & market_convention.
# We would not need once those classes are refactored and moved to stratopan.
my $market_data = {
    get_vol_spread      => sub { 0.01 },
    get_volsurface_data => sub {
        return {
            1 => {
                smile => {
                    25 => 0.17,
                    50 => 0.16,
                    75 => 0.22,
                },
                vol_spread => {
                    50 => 0.01,
                }
            },
            7 => {
                smile => {
                    25 => 0.17,
                    50 => 0.152,
                    75 => 0.18,
                },
                vol_spread => {
                    50 => 0.01,
                }
            },
        };
    },
    get_market_rr_bf => sub {
        return {
            ATM   => 0.01,
            RR_25 => 0.012,
            BF_25 => 0.013,
        };
    },
    get_volatility => sub {
        my $args = shift;
        my %vols = (
            101.00001 => 0.1000005,
            101       => 0.1,
            100.99999 => 0.0999995,
            100.00001 => 0.01000005,
            100       => 0.01,
            99.99999  => 0.00999995,
            99.00001  => 0.1500005,
            99        => 0.15,
            98.99999  => 0.1499995,
        );
        return $vols{$args->{strike}};
    },
    get_atm_volatility => sub {
        return 0.11;
    },
    get_economic_event => sub {
        return ();
    },
    get_overnight_days => sub {
        return 1;
    },
};

my $market_convention = {
    calculate_expiry => sub {
        return 10;
    },
    get_rollover_time => sub {
        # 22:00 GMT as rollover time
        return $now->truncate_to_day->plus_time_interval('22h');
    },
};

sub _get_params {
    my ($ct, $priced_with) = @_;

    my %discount_rate = (
        numeraire => 0.01,
        base      => 0.011,
        quanto    => 0.012,
    );
    my %strikes = (
        CALL        => [100],
        EXPIRYMISS  => [101, 99],
        EXPIRYRANGE => [101, 99],
    );
    return {
        priced_with       => $priced_with,
        spot              => 100,
        strikes           => $strikes{$ct},
        date_start        => $now,
        date_expiry       => $now->plus_time_interval('10d'),
        discount_rate     => $discount_rate{$priced_with},
        q_rate            => 0.002,
        r_rate            => 0.025,
        mu                => 0.023,
        vol               => 0.1,
        payouttime_code   => 0,
        contract_type     => $ct,
        underlying_symbol => 'frxEURUSD',
        market_data       => $market_data,
        market_convention => $market_convention,
    };
}

subtest 'CALL probability' => sub {
    my $pp = _get_params('CALL', 'numeraire');
    my $numeraire = BOM::Product::Pricing::Engine::Slope->new($pp);
    is $numeraire->priced_with, 'numeraire';
    ok looks_like_number($numeraire->probability), 'probability looks like number';
    ok $numeraire->probability <= 1, 'probability <= 1';
    ok $numeraire->probability >= 0, 'probability >= 0';
    is scalar keys %{$numeraire->debug_information}, 1, 'only one set of debug information';
    ok exists $numeraire->debug_information->{CALL}, 'parameters for CALL';
    my $p   = $numeraire->debug_information->{CALL};
    my $ref = $p->{theo_probability}{parameters};
    is $ref->{bs_probability}{amount}, 0.511744030001155, 'correct bs_probability';
    is $ref->{bs_probability}{parameters}{vol},           0.1,   'correct vol for bs';
    is $ref->{bs_probability}{parameters}{mu},            0.023, 'correct mu for bs';
    is $ref->{bs_probability}{parameters}{discount_rate}, 0.01,  'correct discount_rate for bs';
    is $ref->{slope_adjustment}{parameters}{vanilla_vega}{amount}, 6.59860137878187, 'correct vanilla_vega';
    is $ref->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{vol},           0.1,   'correct vol for vanilla_vega';
    is $ref->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{mu},            0.023, 'correct mu for vanilla_vega';
    is $ref->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{discount_rate}, 0.01,  'correct discount_rate for vanilla_vega';

    $pp = _get_params('CALL', 'quanto');
    $quanto = BOM::Product::Pricing::Engine::Slope->new($pp);
    is $quanto->priced_with, 'quanto';
    ok looks_like_number($quanto->probability), 'probability looks like number';
    ok $quanto->probability <= 1, 'probability <= 1';
    ok $quanto->probability >= 0, 'probability >= 0';
    is scalar keys %{$quanto->debug_information}, 1, 'only one set of debug information';
    ok exists $quanto->debug_information->{CALL}, 'parameters for CALL';
    $p   = $quanto->debug_information->{CALL};
    $ref = $p->{theo_probability}{parameters};
    is $ref->{bs_probability}{amount}, 0.511715990000614, 'correct bs_probability';
    is $ref->{bs_probability}{parameters}{vol},           0.1,   'correct vol for bs';
    is $ref->{bs_probability}{parameters}{mu},            0.023, 'correct mu for bs';
    is $ref->{bs_probability}{parameters}{discount_rate}, 0.012, 'correct discount_rate for bs';
    is $ref->{slope_adjustment}{parameters}{vanilla_vega}{amount}, 6.59823982148881, 'correct vanilla_vega';
    is $ref->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{vol},           0.1,   'correct vol for vanilla_vega';
    is $ref->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{mu},            0.023, 'correct mu for vanilla_vega';
    is $ref->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{discount_rate}, 0.012, 'correct discount_rate for vanilla_vega';

    $pp = _get_params('CALL', 'base');
    $base = BOM::Product::Pricing::Engine::Slope->new($pp);
    is $base->priced_with, 'base';
    ok looks_like_number($base->probability), 'probability looks like number';
    ok $base->probability <= 1, 'probability <= 1';
    ok $base->probability >= 0, 'probability >= 0';
    is scalar keys %{$base->debug_information}, 1, 'only one set of debug information';
    ok exists $base->debug_information->{CALL}, 'parameters for CALL';
    $p = $base->debug_information->{CALL};
    my $ref = $p->{theo_probability}{parameters};
    is $ref->{numeraire_probability}{parameters}{bs_probability}{amount}, 0.511533767442995, 'correct bs_probability';
    is $ref->{numeraire_probability}{parameters}{bs_probability}{parameters}{vol},           0.1,   'correct vol for bs';
    is $ref->{numeraire_probability}{parameters}{bs_probability}{parameters}{mu},            0.023, 'correct mu for bs';
    is $ref->{numeraire_probability}{parameters}{bs_probability}{parameters}{discount_rate}, 0.025, 'correct discount_rate for bs';
    is $ref->{numeraire_probability}{parameters}{slope_adjustment}{parameters}{vanilla_vega}{amount}, 6.595890181924, 'correct vanilla_vega';
    is $ref->{numeraire_probability}{parameters}{slope_adjustment}{parameters}{vanilla_vega}{parameters}{vol}, 0.1,   'correct vol for vanilla_vega';
    is $ref->{numeraire_probability}{parameters}{slope_adjustment}{parameters}{vanilla_vega}{parameters}{mu},  0.023, 'correct mu for vanilla_vega';
    is $ref->{numeraire_probability}{parameters}{slope_adjustment}{parameters}{vanilla_vega}{parameters}{discount_rate}, 0.025,
        'correct discount_rate for vanilla_vega';
    is $ref->{base_vanilla_probability}{amount}, 0.692321231176061, 'correct base_vanilla_probability';
    is $ref->{base_vanilla_probability}{parameters}{mu},            0.023, 'correct mu for base_vanilla_probability';
    is $ref->{base_vanilla_probability}{parameters}{discount_rate}, 0.011, 'correct discount_rate for base_vanilla_probability';
};

subtest 'EXPIRYMISS probability' => sub {
    my $pp = _get_params('EXPIRYMISS', 'numeraire');
    my $numeraire = BOM::Product::Pricing::Engine::Slope->new($pp);
    is $numeraire->priced_with, 'numeraire';
    ok looks_like_number($numeraire->probability), 'probability looks like number';
    ok $numeraire->probability <= 1, 'probability <= 1';
    ok $numeraire->probability >= 0, 'probability >= 0';
    is scalar keys %{$numeraire->debug_information}, 2, 'only one set of debug information';
    ok exists $numeraire->debug_information->{CALL}, 'parameters for CALL';
    ok exists $numeraire->debug_information->{PUT},  'parameters for PUT';
    my $call = $numeraire->debug_information->{CALL};
    is $call->{theo_probability}{amount}, 0.00063008065732667, 'correct tv for CALL';
    my $ref_call = $call->{theo_probability}{parameters};
    is $ref_call->{bs_probability}{amount}, 0.283800829253145, 'correct bs_probability';
    is $ref_call->{bs_probability}{parameters}{vol},           0.1,   'correct vol for bs';
    is $ref_call->{bs_probability}{parameters}{mu},            0.023, 'correct mu for bs';
    is $ref_call->{bs_probability}{parameters}{discount_rate}, 0.01,  'correct discount_rate for bs';
    is $ref_call->{bs_probability}{parameters}{strikes}->[0], 101, 'correct strike for bs';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{amount}, 5.66341497191071, 'correct vanilla_vega';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{vol},           0.1,   'correct vol for vanilla_vega';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{mu},            0.023, 'correct mu for vanilla_vega';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{discount_rate}, 0.01,  'correct discount_rate for vanilla_vega';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{strikes}->[0], 101, 'correct strike for vanilla_vega';
    my $put = $numeraire->debug_information->{PUT};
    is $put->{theo_probability}{amount}, 0.637437489808321, 'correct tv for PUT';
    my $ref_put = $put->{theo_probability}{parameters};
    is $ref_put->{bs_probability}{amount}, 0.337968183618001, 'correct bs_probability';
    is $ref_put->{bs_probability}{parameters}{vol},           0.15,  'correct vol for bs';
    is $ref_put->{bs_probability}{parameters}{mu},            0.023, 'correct mu for bs';
    is $ref_put->{bs_probability}{parameters}{discount_rate}, 0.01,  'correct discount_rate for bs';
    is $ref_put->{bs_probability}{parameters}{strikes}->[0], 99, 'correct strike for bs';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{amount}, 5.98938612380042, 'correct vanilla_vega';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{vol},           0.15,  'correct vol for vanilla_vega';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{mu},            0.023, 'correct mu for vanilla_vega';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{discount_rate}, 0.01,  'correct discount_rate for vanilla_vega';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{strikes}->[0], 99, 'correct strike for vanilla_vega';
};

subtest 'EXPIRYRANGE probability' => sub {
    my $pp = _get_params('EXPIRYRANGE', 'numeraire');
    my $numeraire = BOM::Product::Pricing::Engine::Slope->new($pp);
    is $numeraire->priced_with, 'numeraire';
    ok looks_like_number($numeraire->probability), 'probability looks like number';
    ok $numeraire->probability <= 1, 'probability <= 1';
    ok $numeraire->probability >= 0, 'probability >= 0';
    is scalar keys %{$numeraire->debug_information}, 3, 'only one set of debug information';
    ok exists $numeraire->debug_information->{CALL},                   'parameters for CALL';
    ok exists $numeraire->debug_information->{PUT},                    'parameters for PUT';
    ok exists $numeraire->debug_information->{discounted_probability}, 'parameters for discounted_probability';
    is $numeraire->debug_information->{discounted_probability}, 0.999726064924327, 'correct discounted probability';
    my $call = $numeraire->debug_information->{CALL};
    is $call->{theo_probability}{amount}, 0.00063008065732667, 'correct tv for CALL';
    my $ref_call = $call->{theo_probability}{parameters};
    is $ref_call->{bs_probability}{amount}, 0.283800829253145, 'correct bs_probability';
    is $ref_call->{bs_probability}{parameters}{vol},           0.1,   'correct vol for bs';
    is $ref_call->{bs_probability}{parameters}{mu},            0.023, 'correct mu for bs';
    is $ref_call->{bs_probability}{parameters}{discount_rate}, 0.01,  'correct discount_rate for bs';
    is $ref_call->{bs_probability}{parameters}{strikes}->[0], 101, 'correct strike for bs';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{amount}, 5.66341497191071, 'correct vanilla_vega';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{vol},           0.1,   'correct vol for vanilla_vega';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{mu},            0.023, 'correct mu for vanilla_vega';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{discount_rate}, 0.01,  'correct discount_rate for vanilla_vega';
    is $ref_call->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{strikes}->[0], 101, 'correct strike for vanilla_vega';
    my $put = $numeraire->debug_information->{PUT};
    is $put->{theo_probability}{amount}, 0.637437489808321, 'correct tv for PUT';
    my $ref_put = $put->{theo_probability}{parameters};
    is $ref_put->{bs_probability}{amount}, 0.337968183618001, 'correct bs_probability';
    is $ref_put->{bs_probability}{parameters}{vol},           0.15,  'correct vol for bs';
    is $ref_put->{bs_probability}{parameters}{mu},            0.023, 'correct mu for bs';
    is $ref_put->{bs_probability}{parameters}{discount_rate}, 0.01,  'correct discount_rate for bs';
    is $ref_put->{bs_probability}{parameters}{strikes}->[0], 99, 'correct strike for bs';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{amount}, 5.98938612380042, 'correct vanilla_vega';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{vol},           0.15,  'correct vol for vanilla_vega';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{mu},            0.023, 'correct mu for vanilla_vega';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{discount_rate}, 0.01,  'correct discount_rate for vanilla_vega';
    is $ref_put->{slope_adjustment}{parameters}{vanilla_vega}{parameters}{strikes}->[0], 99, 'correct strike for vanilla_vega';
};

subtest 'unsupported contract_type' => sub {
    lives_ok {
        my $pp = _get_params('unsupported', 'numeraire');
        $pp->{strikes} = [100];
        my $slope = BOM::Product::Pricing::Engine::Slope->new($pp);
        is $slope->probability,       1,                             'probabilility is 1';
        is $slope->bs_probability,    1,                             'probabilility is 1';
        ok $slope->error,             'has error';
        like $slope->error,           qr/Unsupported contract type/, 'correct error message';
        is $slope->risk_markup,       0,                             'risk_markup is zero';
        is $slope->commission_markup, 0,                             'commission_markup is zero';
    }
    'doesn\'t die if contract type is unsupported';
};

subtest 'unregconized priced_with' => sub {
    lives_ok {
        my $pp = _get_params('CALL', 'unregconized');
        $pp->{discount_rate} = 0.01;
        my $slope = BOM::Product::Pricing::Engine::Slope->new($pp);
        is $slope->probability,       1,                            'probabilility is 1';
        is $slope->bs_probability,    1,                            'probabilility is 1';
        is $slope->risk_markup,       0,                            'risk_markup is zero';
        is $slope->commission_markup, 0,                            'commission_markup is zero';
        ok $slope->error,             'has error';
        like $slope->error,           qr/Unrecognized priced_with/, 'correct error message';
    }
    'doesn\'t die if priced_with is unregconized';
};

subtest 'barrier error' => sub {
    lives_ok {
        my $pp = _get_params('CALL', 'numeraire');
        $pp->{strikes} = [];
        my $slope = BOM::Product::Pricing::Engine::Slope->new($pp);
        ok $slope->error,             'has error';
        like $slope->error,           qr/Barrier error for/, 'correct error message';
        is $slope->probability,       1, 'probabilility is 1';
        is $slope->bs_probability,    1, 'probabilility is 1';
        is $slope->risk_markup,       0, 'risk_markup is zero';
        is $slope->commission_markup, 0, 'commission_markup is zero';
    }
    'doesn\'t die if strikes are undefined';

    lives_ok {
        my $pp = _get_params('EXPIRYMISS', 'numeraire');
        shift @{$pp->{strikes}};
        my $slope = BOM::Product::Pricing::Engine::Slope->new($pp);
        ok $slope->error,             'has error';
        like $slope->error,           qr/Barrier error for/, 'correct error message';
        is $slope->probability,       1, 'probabilility is 1';
        is $slope->bs_probability,    1, 'probabilility is 1';
        is $slope->risk_markup,       0, 'risk_markup is zero';
        is $slope->commission_markup, 0, 'commission_markup is zero';
    }
    'doesn\'t die if strikes are undefined';
};
