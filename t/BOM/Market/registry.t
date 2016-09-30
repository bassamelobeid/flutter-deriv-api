#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;

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
        [sort 'forex', 'indices', 'commodities', 'volidx', 'stocks'], "correct list of financial markets";
};

subtest 'Market builds or configs test' => sub {
    subtest 'config' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $config = $registry->get('config');

        isa_ok $config, 'BOM::Market';
        ok !$config->display_name, 'Display Name';
        ok !$config->equity;
        ok !$config->reduced_display_decimals, 'Reduced Display Decimals';
        is $config->asset_type,         'asset';
        is $config->deep_otm_threshold, 0.10;
        is $config->base_commission, 0.05,              'base commission default to 0.05';
        ok !$config->markups->apply_butterfly_markup,      'Butterfly Markup';
        ok !$config->markups->apply_traded_markets_markup, 'Market Markup';
        ok !$config->foreign_bs_probability;
        ok !$config->absolute_barrier_multiplier;
        ok !$config->display_order;

        ok !$config->providers->[0];
        is $config->license, 'realtime';
        ok !$config->official_ohlc,         'Official OHLC';
        ok !$config->integer_barrier,       'non integer barrier';
    };

    subtest 'forex' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $forex = $registry->get('forex');

        isa_ok $forex, 'BOM::Market';
        is $forex->display_name, 'Forex', 'Correct display name';
        is $forex->display_order, 1;
        ok !$forex->equity;
        ok $forex->reduced_display_decimals;
        is $forex->asset_type,         'currency';
        is $forex->deep_otm_threshold, 0.05;

        is $forex->base_commission, 0.05, 'base commission of 0.05';
        ok $forex->markups->apply_butterfly_markup,      'Butterfly Markup';
        ok $forex->markups->apply_traded_markets_markup, 'Market Markup';
        ok $forex->foreign_bs_probability;
        ok $forex->absolute_barrier_multiplier;

        cmp_deeply($forex->providers, ['idata', 'panda', 'olsen']);

        is $forex->license, 'realtime';
        ok !$forex->official_ohlc;
        ok !$forex->integer_barrier, 'non integer barrier';
    };

    subtest 'commodities' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $commodities = $registry->get('commodities');

        isa_ok $commodities, 'BOM::Market';
        is $commodities->display_name,  'Commodities';
        is $commodities->display_order, 4;
        ok !$commodities->equity;
        ok $commodities->reduced_display_decimals;
        is $commodities->deep_otm_threshold, 0.10;
        is $commodities->asset_type,         'currency';
        is $commodities->base_commission, 0.05, 'base commission of 0.05';

        ok !$commodities->markups->apply_butterfly_markup, 'Butterfly Markup';
        ok $commodities->markups->apply_traded_markets_markup, 'Market Markup';
        ok !$commodities->foreign_bs_probability;
        ok $commodities->absolute_barrier_multiplier;

        cmp_deeply($commodities->providers,, ['idata', 'panda', 'sd'],);

        is $commodities->license, 'realtime';
        ok !$commodities->official_ohlc;
        ok !$commodities->integer_barrier, 'non integer barrier';
    };

    subtest 'indices' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $indices = $registry->get('indices');

        isa_ok $indices, 'BOM::Market';
        is $indices->display_name,  'Indices';
        is $indices->display_order, 2;
        ok $indices->equity;
        ok !$indices->reduced_display_decimals;
        is $indices->deep_otm_threshold, 0.10;
        is $indices->asset_type,         'index';

        is $indices->base_commission, 0.025, 'base commission of 0.025';

        ok !$indices->markups->apply_butterfly_markup, 'Butterfly Markup';
        ok $indices->markups->apply_traded_markets_markup, 'Market Markup';
        ok !$indices->foreign_bs_probability;
        ok !$indices->absolute_barrier_multiplier;

        cmp_deeply($indices->providers, ['idata', 'telekurs']);

        is $indices->license, 'daily';
        ok $indices->official_ohlc;
        ok $indices->integer_barrier, 'Integer barrier';
    };

    subtest 'random' => sub {
        my $registry = BOM::Market::Registry->instance;

        my $random = $registry->get('volidx');

        isa_ok $random, 'BOM::Market';
        is $random->display_name,  'Volatility Indices';
        is $random->display_order, 5;
        ok !$random->equity;
        ok $random->reduced_display_decimals;
        is $random->deep_otm_threshold, 0.025;
        is $random->asset_type,         'synthetic';
        is $random->base_commission, 0.015, 'base commission of 0.015';
        ok !$random->markups->apply_butterfly_markup,      'Butterfly Markup';
        ok !$random->markups->apply_traded_markets_markup, 'Market Markup';
        ok !$random->foreign_bs_probability;
        ok $random->absolute_barrier_multiplier;

        cmp_deeply($random->providers, ['random',]);
        is $random->license, 'realtime';
        ok !$random->official_ohlc;
        ok !$random->integer_barrier,       'non integer barrier';
    };
};

done_testing;
