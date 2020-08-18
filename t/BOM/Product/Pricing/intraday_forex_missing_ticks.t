use strict;
use warnings;

use Test::Most tests => 2;
use Test::Warnings;
use File::Spec;
use YAML::XS qw(LoadFile);
use Date::Utility;
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Text::CSV;
use BOM::Market::DataDecimate;

use List::Util qw(first max);
use Data::Decimate qw(decimate);

use Test::BOM::UnitTestPrice;
use BOM::Test::Data::Utility::UnitTestRedis;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

BOM::Config::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom-test/feed/combined');

my $date_start = Date::Utility->new(1352345145);
note('Pricing on ' . $date_start->datetime);
my $date_pricing = $date_start;
my $date_expiry  = $date_start->plus_time_interval('1000s');
my $underlying   = create_underlying('frxUSDJPY', $date_pricing);

my $offerings_cfg = BOM::Config::Runtime->instance->get_offerings_config;

my $missing_ticks = data_from_csv('t/BOM/Product/Pricing/missing_ticks.csv');

my @rev_ticks;
foreach my $single_data (@$missing_ticks) {

#1352344320
    next if ($single_data->{epoch} >= 1352344320 and $single_data->{epoch} <= 1352344320 + 60);
#1352344500 till +60*10
    next if ($single_data->{epoch} >= 1352344500 and $single_data->{epoch} <= 1352344500 + 600);
    push @rev_ticks, $single_data;
}

my $decimate_cache = BOM::Market::DataDecimate->new({market => 'forex'});
my $decimate_data  = Data::Decimate::decimate($decimate_cache->sampling_frequency->seconds, \@rev_ticks);

my $decimate_key = $decimate_cache->_make_key('frxUSDJPY', 1);

subtest "intraday_forex_data_with_missing_ticks" => sub {

    foreach my $single_data (@$decimate_data) {
        my $dec_epoch = $single_data->{decimate_epoch};
        if (($dec_epoch >= 1352344515 and $dec_epoch <= 1352345100) or ($dec_epoch >= 1352344335 and $dec_epoch <= 1352344380)) {
            is $single_data->{count}, '0', "count should be 0";

        }
    }
};

my $recorded_date = $date_start->truncate_to_day;

sub data_from_csv {
    my $filename = shift;

    open(my $fh, '<:utf8', $filename) or die "Can't open $filename: $!";

    my $header = '';
    while (<$fh>) {
        if (/^symbol,/x) {
            $header = $_;
            last;
        }
    }

    my $csv = Text::CSV->new or die "Text::CSV error: " . Text::CSV->error_diag;

    $csv->parse($header);
    $csv->column_names([$csv->fields]);

    my @datas;
    while (my $row = $csv->getline_hr($fh)) {
        push @datas, $row;
    }

    $csv->eof or $csv->error_diag;
    close $fh;

    return \@datas;
}
