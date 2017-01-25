use strict;
use warnings;

use Test::Most tests => 4;
use File::Spec;
use YAML::XS qw(LoadFile);
use LandingCompany::Offerings qw(get_offerings_with_filter);
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
#use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

#my $at = BOM::Market::AggTicks->new;
#$at->flush;

BOM::Platform::Runtime->instance->app_config->system->directory->feed('/home/git/regentmarkets/bom/t/data/feed/');
#BOM::Test::Data::Utility::FeedTestDatabase::setup_ticks('frxUSDJPY/8-Nov-12.dump');

my $expected   = LoadFile('/home/git/regentmarkets/bom/t/BOM/Product/Pricing/intraday_forex_config.yml');
my $date_start = Date::Utility->new(1352345145);
note('Pricing on ' . $date_start->datetime);
my $date_pricing    = $date_start;
my $date_expiry     = $date_start->plus_time_interval('1000s');
my $underlying      = create_underlying('frxUSDJPY', $date_pricing);
my $barrier         = 'S3P';
my $barrier_low     = 'S-3P';
my $payout          = 100;
my $payout_currency = 'GBP';
my $duration        = 3600;

my $offerings_cfg = BOM::Platform::Runtime->instance->get_offerings_config;

my $missing_ticks = data_from_csv('t/BOM/Product/Pricing/missing_ticks.csv');


#BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;

my @rev_ticks;
foreach my $single_data (@$missing_ticks) {
  print "###:" . $single_data->{symbol} . "," . $single_data->{epoch} . "," . $single_data->{quote} . "\n";

#1352344320
  next if ($single_data->{epoch} >= 1352344320 and $single_data->{epoch} <= 1352344320 + 60);
#1352344500 till +60*10
  next if ($single_data->{epoch} >= 1352344500 and $single_data->{epoch} <= 1352344500 + 600);
  push @rev_ticks, $single_data;
#   BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
#            underlying => 'frxUSDJPY',
#            epoch      => $single_data->{epoch} + 10000,
#            quote      => $single_data->{quote},
#        });
}

my $start = $date_start->epoch - 7200;
$start = $start - $start % 15;
my $first_agg = $start - 15;

#my $hist_ticks = $underlying->ticks_in_between_start_end({
#        start_time => $first_agg,
#        end_time   => $date_start->epoch,
#    });

my @rev_ticks2 = reverse @rev_ticks;

my $decimate_cache = BOM::Market::DataDecimate->new();
my $decimate_data = Data::Decimate::decimate($decimate_cache->sampling_frequency->seconds, \@rev_ticks);

my $decimate_key = $decimate_cache->_make_key('frxUSDJPY', 1);

foreach my $single_data (@$decimate_data) {
#        $decimate_cache->_update(
#            $decimate_cache->redis_write,
#            $decimate_key,
#            $single_data->{decimate_epoch},
#            $decimate_cache->encoder->encode($single_data));
my $agg_epoch = $single_data->{decimate_epoch};
       if($agg_epoch) {
       print "### : " . $single_data->{symbol} . "," . $single_data->{epoch} . "," . $agg_epoch . "," . ",count=$single_data->{count}\n";
}
}

my $agg_t = $decimate_cache->decimate_cache_get({
	underlying => $underlying,
        start_epoch => $start,
        end_epoch  => $date_start->epoch,
        backprice => 0,
});

#foreach my $single_data (@$agg_t) {
#       my $agg_epoch = $single_data->{decimate_epoch};
#       if($agg_epoch) {
#       print "### : " . $single_data->{symbol} . "," . $single_data->{epoch} . "," . $agg_epoch . "," . ",count=$single_data->{count}\n";
#         if($agg_epoch==1352344500-15) $prev_tick = $single_data;
#       }else {
#	print ">>> : " . $single_data->{symbol} . "," . $single_data->{epoch} . "," . ",count=$single_data->{count}\n";
#       }
#}

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
