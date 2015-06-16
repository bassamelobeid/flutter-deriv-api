use strict;
use warnings;

use Test::Most tests => 5;
use Test::Exception;
use Test::FailWarnings;

use BOM::Test::Runtime qw(:normal);
use BOM::Market;
use BOM::Market::Registry;

throws_ok { BOM::Market->new() } qr/Attribute \(name\) is required/, 'Name is Required';

subtest 'outlier tick' => sub {
    foreach my $market (BOM::Market::Registry->instance->display_markets) {
        subtest $market->name => sub {
            my $ot = $market->outlier_tick;
            ok defined $ot, 'has a defined outlier tick level';
            cmp_ok $ot, '>',  0,    '... which is positive';
            cmp_ok $ot, '<=', 0.20, '... and less than or equal to 20%';

        };
    }
};

subtest 'disabled' => sub {
    subtest 'simple' => sub {
        my $bfm = new_ok('BOM::Market' => [{'name' => 'forex'}]);
        ok !$bfm->disabled, 'Forex Not disabled';
    };
};

subtest 'disable_iv' => sub {
    BOM::Platform::Runtime->instance->app_config->quants->markets->disable_iv(['stocks']);
    my $bfm = new_ok('BOM::Market' => [{'name' => 'stocks'}]);
    ok $bfm->disable_iv;

    $bfm = new_ok('BOM::Market' => [{'name' => 'forex'}]);
    ok !$bfm->disable_iv;
};

subtest 'deep_otm_threshold' => sub {
    my $forex = new_ok('BOM::Market' => [{'name' => 'forex'}]);
    is $forex->deep_otm_threshold, 2.5;
    my $commodities = new_ok('BOM::Market' => [{'name' => 'commodities'}]);
    is $commodities->deep_otm_threshold, 5;

    my $original_deep_otm_threshold = BOM::Platform::Runtime->instance->app_config->quants->commission->deep_otm_threshold;
    BOM::Platform::Runtime->instance->app_config->quants->commission->deep_otm_threshold('{"forex" : 10 }');
    $forex->clear_deep_otm_threshold;
    is $forex->deep_otm_threshold, 10;
    $commodities->clear_deep_otm_threshold;
    ok !$commodities->deep_otm_threshold;

    BOM::Platform::Runtime->instance->app_config->quants->commission->deep_otm_threshold($original_deep_otm_threshold);
};
