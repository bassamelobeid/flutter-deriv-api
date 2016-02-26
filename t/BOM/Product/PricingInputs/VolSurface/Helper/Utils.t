use Test::Most;
use Test::FailWarnings;
use Test::MockTime qw( set_absolute_time );
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::MarketData::VolSurface::Utils;
use BOM::Market::Underlying;

subtest "default_bloomberg_cutoff" => sub {
    plan tests => 3;
    my $forex = BOM::Market::Underlying->new('frxUSDJPY');
    my $util  = BOM::MarketData::VolSurface::Utils->new();
    is($util->default_bloomberg_cutoff($forex), 'New York 10:00', 'Gets New York 10:00 for forex market');

    my $commodity = BOM::Market::Underlying->new('frxBROUSD');
    is($util->default_bloomberg_cutoff($commodity), 'New York 10:00', 'Default cutoff for a commodity.');

    my $indices = BOM::Market::Underlying->new('SPC');
    isnt($util->default_bloomberg_cutoff($indices), 'New York 10:00', 'Anything other than New York 10:00 for indices');
};

subtest "NY1700_rollover_date_on" => sub {
    plan tests => 2;
    my $date_apr = Date::Utility->new('12-APR-12 16:00');
    my $util     = BOM::MarketData::VolSurface::Utils->new();
    is($util->NY1700_rollover_date_on($date_apr)->datetime, '2012-04-12 21:00:00', 'Correct rollover time in April');
    my $date_nov = Date::Utility->new('12-NOV-12 16:00');
    is($util->NY1700_rollover_date_on($date_nov)->datetime, '2012-11-12 22:00:00', 'Correct rollover time in November');
};

subtest "effective_date_for" => sub {
    plan tests => 2;
    my $date_apr = Date::Utility->new('12-APR-12 16:00');
    my $util     = BOM::MarketData::VolSurface::Utils->new();
    is($util->effective_date_for($date_apr)->date, '2012-04-12', 'Correct effective date in April');
    my $date_nov = Date::Utility->new('12-NOV-12 16:00');
    $util = BOM::MarketData::VolSurface::Utils->new();
    is($util->effective_date_for($date_nov)->date, '2012-11-12', 'Correct effective date in November');
};

subtest default_bloomberg_cutoff => sub {
    plan tests => 4;

    my $util = BOM::MarketData::VolSurface::Utils->new;

    foreach my $date_str (qw(2012-10-05 2012-10-06 2012-10-07 2012-10-08)) {
        set_absolute_time(Date::Utility->new($date_str . ' 10:00:00')->epoch);

        my $AS51 = BOM::Market::Underlying->new('AS51');

        is($util->default_bloomberg_cutoff($AS51), 'UTC 06:00', 'Cutoff on Saturday before a DST spring forward.');
    }
};

done_testing;
