use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::Config;
use BOM::Config::Quants;

my $quants_mock = Test::MockModule->new("BOM::Config::Quants");

subtest "market_pricing_limits - unsupported currency" => sub {

    my $currencies = ['TEST1', 'TEST2', 'BTC', 'TEST3'];

    my $dd_metric_counter = 0;
    my $dd_metric_name    = 'bom_config.quants.market_pricing_limits.unsupported_currency';

    $quants_mock->mock(
        stats_inc => sub {
            my ($metric) = @_;
            $dd_metric_counter++ if ($metric eq $dd_metric_name);
        });

    ok BOM::Config::quants();

    my $limits = BOM::Config::Quants::market_pricing_limits($currencies);

    is $dd_metric_counter, 3, 'increment DD metric when an unsupported currency is used';

    $quants_mock->unmock_all();

};

done_testing();
