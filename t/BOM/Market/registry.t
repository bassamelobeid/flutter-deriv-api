#!/usr/bin/env perl

use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;

use BOM::Test::Runtime qw(:normal);
use BOM::Market::Registry;

subtest 'Build Registry' => sub {
    plan tests => 2;
    my $registry;

    lives_ok {
        $registry = BOM::Market::Registry->instance;
    }
    'Able to load registry';

    ok $registry->get('forex'), 'We get forex';
};

subtest 'display_markets' => sub {
    plan tests => 1;
    my $registry = BOM::Market::Registry->instance;

    eq_or_diff [sort map { $_->name } $registry->display_markets],
        [sort 'forex', 'indices', 'commodities', 'random', 'stocks'], "correct list of financial markets";
};

subtest 'Market builds or configs test' => sub {
    subtest 'config' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $config = $registry->get('config');

        isa_ok $config, 'BOM::Market';
        ok !$config->display_name, 'Display Name';
        ok !$config->equity;
        ok !$config->disabled,                 'disabled';
        ok !$config->reduced_display_decimals, 'Reduced Display Decimals';
        is $config->asset_type,         'asset';
        is $config->deep_otm_threshold, 0.10;
        ok !$config->markups->digital_spread,              'Digital Spread';
        ok !$config->markups->apply_butterfly_markup,      'Butterfly Markup';
        ok !$config->markups->apply_traded_markets_markup, 'Market Markup';
        is $config->vol_cut_off, 'Default', 'Vol cut off';
        ok !$config->foreign_bs_probability;
        ok !$config->absolute_barrier_multiplier;
        ok !$config->display_order;

        ok !$config->providers->[0];
        is $config->license, 'realtime';
        ok !$config->official_ohlc,         'Official OHLC';
        ok !$config->integer_barrier, 'non integer barrier';
        ok !$config->integer_number_of_day, 'integer number of day';
    };

    subtest 'forex' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $forex = $registry->get('forex');

        isa_ok $forex, 'BOM::Market';
        is $forex->display_name, 'Forex', 'Correct display name';
        is $forex->display_order, 1;
        ok !$forex->equity;
        ok !$forex->disabled, 'But its not disabled';
        ok $forex->reduced_display_decimals;
        is $forex->asset_type,         'currency';
        is $forex->deep_otm_threshold, 0.05;

        cmp_deeply(
            $forex->markups->digital_spread,
            {
                'ASIAND'      => 3.5,
                'ASIANU'      => 3.5,
                'CALL'        => 3.5,
                'DIGITDIFF'   => 3.5,
                'DIGITMATCH'  => 3.5,
                'EXPIRYMISS'  => 3.5,
                'EXPIRYRANGE' => 3.5,
                'NOTOUCH'     => 4,
                'ONETOUCH'    => 4,
                'PUT'         => 3.5,
                'RANGE'       => 5,
                'UPORDOWN'    => 5,
            },
        );
        ok $forex->markups->apply_butterfly_markup,      'Butterfly Markup';
        ok $forex->markups->apply_traded_markets_markup, 'Market Markup';
        is $forex->vol_cut_off, 'NY1000', 'Vol cut off';
        ok $forex->foreign_bs_probability;
        ok $forex->absolute_barrier_multiplier;

        cmp_deeply($forex->providers, ['panda', 'idata', 'olsen']);

        is $forex->license, 'realtime';
        ok !$forex->official_ohlc;
        ok !$forex->integer_barrier, 'non integer barrier';
        ok $forex->integer_number_of_day, 'integer number of day';
    };

    subtest 'commodities' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $commodities = $registry->get('commodities');

        isa_ok $commodities, 'BOM::Market';
        is $commodities->display_name,  'Commodities';
        is $commodities->display_order, 4;
        ok !$commodities->equity;
        ok !$commodities->disabled;
        ok $commodities->reduced_display_decimals;
        is $commodities->deep_otm_threshold, 0.10;
        is $commodities->asset_type,         'currency';

        cmp_deeply(
            $commodities->markups->digital_spread,
            {
                'ASIAND'      => 4,
                'ASIANU'      => 4,
                'CALL'        => 4,
                'DIGITDIFF'   => 4,
                'DIGITMATCH'  => 4,
                'EXPIRYMISS'  => 4,
                'EXPIRYRANGE' => 4,
                'NOTOUCH'     => 7,
                'ONETOUCH'    => 7,
                'PUT'         => 4,
                'RANGE'       => 10,
                'UPORDOWN'    => 10,
            },
        );

        ok !$commodities->markups->apply_butterfly_markup, 'Butterfly Markup';
        ok $commodities->markups->apply_traded_markets_markup, 'Market Markup';
        is $commodities->vol_cut_off, 'NY1000', 'Vol cut off';
        ok !$commodities->foreign_bs_probability;
        ok $commodities->absolute_barrier_multiplier;

        cmp_deeply($commodities->providers,, ['panda', 'idata', 'sd'],);

        is $commodities->license, 'realtime';
        ok !$commodities->official_ohlc;
        ok !$commodities->integer_barrier, 'non integer barrier';
        ok $commodities->integer_number_of_day, 'integer number of day';
    };

    subtest 'indices' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $indices = $registry->get('indices');

        isa_ok $indices, 'BOM::Market';
        is $indices->display_name,  'Indices';
        is $indices->display_order, 2;
        ok $indices->equity;
        ok !$indices->disabled;
        ok !$indices->reduced_display_decimals;
        is $indices->deep_otm_threshold, 0.10;
        is $indices->asset_type,         'index';

        cmp_deeply(
            $indices->markups->digital_spread,
            {
                'ASIAND'      => 4,
                'ASIANU'      => 4,
                'CALL'        => 4,
                'DIGITDIFF'   => 4,
                'DIGITMATCH'  => 4,
                'EXPIRYMISS'  => 4,
                'EXPIRYRANGE' => 4,
                'NOTOUCH'     => 6,
                'ONETOUCH'    => 6,
                'PUT'         => 4,
                'RANGE'       => 8,
                'UPORDOWN'    => 8,
            },
        );

        ok !$indices->markups->apply_butterfly_markup, 'Butterfly Markup';
        ok $indices->markups->apply_traded_markets_markup, 'Market Markup';
        is $indices->vol_cut_off, 'Default', 'Vol cut off';
        ok !$indices->foreign_bs_probability;
        ok !$indices->absolute_barrier_multiplier;

        cmp_deeply($indices->providers, ['idata', 'telekurs', 'tenfore']);

        is $indices->license, 'daily';
        ok $indices->official_ohlc;
        ok $indices->integer_barrier, 'Integer barrier';
        ok !$indices->integer_number_of_day, 'integer number of day';
    };

    subtest 'random' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $random = $registry->get('random');

        isa_ok $random, 'BOM::Market';
        is $random->display_name,  'Randoms';
        is $random->display_order, 5;
        ok !$random->equity;
        ok !$random->disabled;
        ok $random->reduced_display_decimals;
        is $random->deep_otm_threshold, 0.025;
        is $random->asset_type,         'synthetic';

        cmp_deeply(
            $random->markups->digital_spread,
            {
                'ASIAND'      => 3,
                'ASIANU'      => 3,
                'CALL'        => 3,
                'DIGITDIFF'   => 3,
                'DIGITMATCH'  => 3,
                'EXPIRYMISS'  => 3,
                'EXPIRYRANGE' => 3,
                'NOTOUCH'     => 3,
                'ONETOUCH'    => 3,
                'PUT'         => 3,
                'RANGE'       => 3,
                'UPORDOWN'    => 3,
            },
        );
        ok !$random->markups->apply_butterfly_markup,      'Butterfly Markup';
        ok !$random->markups->apply_traded_markets_markup, 'Market Markup';
        is $random->vol_cut_off, 'Default', 'Vol cut off';
        ok !$random->foreign_bs_probability;
        ok $random->absolute_barrier_multiplier;

        cmp_deeply($random->providers, ['random',]);
        is $random->license, 'realtime';
        ok !$random->official_ohlc;
        ok !$random->integer_barrier, 'non integer barrier';
        ok !$random->integer_number_of_day, 'integer number of day';
    };
};

done_testing;
