use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Warnings;
use Test::Exception;

use BOM::MarketData qw(create_underlying_db);
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

subtest 'suspended underlyings' => sub {

    $app_config->set({'quants.underlyings.suspend_buy' => []});

    my $include_before = create_underlying_db->symbols_for_intraday_fx;
    my $exclude_before = create_underlying_db->symbols_for_intraday_fx(1);

    $app_config->set({'quants.underlyings.suspend_buy' => ['frxEURUSD', 'frxAUDJPY']});

    my $include_after = create_underlying_db->symbols_for_intraday_fx;
    my $exclude_after = create_underlying_db->symbols_for_intraday_fx(1);

    is $include_before, $include_after, 'It should include suspended underlyings';
    is $exclude_after, ($exclude_before - 2), '2 underlyings are suspended';

};

done_testing;
