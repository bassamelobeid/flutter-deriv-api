
use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying);
#use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Market::DataDecimate;
use Text::CSV;
use BOM::Config::Redis;

BOM::Config::Redis::redis_replicated_write()->set('economic_events_cache_snapshot', time);

#add test case here

my $data = data_from_csv('t/BOM/Market/DecimateCache/sampledata.csv');

# Dummy event which is not used
my $events = [{
        release_date => 1579203255,
        symbol       => 'USD',
        event_name   => "Non-Farm Employment Change",
        custom       => {
            frxUSDJPY => {
                vol_change   => 0.3,
                decay_factor => 4,
                duration     => 0
            },
        },
    }];

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events        => $events,
        recorded_date => 1479203250
    });

subtest "decimate_cache_insert_and_retrieve" => sub {
    my $decimate_cache = BOM::Market::DataDecimate->new({market => 'forex'});

    ok $decimate_cache, "Instance has been created";

    is scalar(@$data), '142', "check number of test data";

    for (my $i = 0; $i <= 141; $i++) {
        $decimate_cache->data_cache_insert_raw($data->[$i]);
    }

    my $data_out = $decimate_cache->_get_num_data_from_cache({
        symbol    => 'frxUSDJPY',
        num       => 142,
        end_epoch => 1479203250,
    });

    is scalar(@$data_out), '142', "retrieved 142 datas from cache";

    is $data_out->[0]->{epoch},   '1479203101', "epoch is correct for first raw data";
    is $data_out->[141]->{epoch}, '1479203250', "epoch is correct for last raw data";

    # test insert_decimate
    # try get all decimated datas
    # last data in our sample
    # USDJPY,1479203250,1479203250,108.254,108.256,108.257
    for (my $i = 1479203115; $i <= 1479203250; $i = $i + 15) {
        $decimate_cache->data_cache_insert_decimate('frxUSDJPY', $i);
    }

    my $decimate_data = $decimate_cache->_get_decimate_from_cache({
        symbol      => 'frxUSDJPY',
        start_epoch => 1479203101,
        end_epoch   => 1479203250,
    });

    is scalar(@$decimate_data), '10', "retrieved 10 decimated datas";

    is $decimate_data->[0]->{epoch}, '1479203114', "epoch is correct for first decimate data";
    is $decimate_data->[9]->{epoch}, '1479203250', "epoch is correct for first decimate data";

    #let's check the value as well
    #frxUSDJPY,1479203114,1479203115,108.285,108.286,108.288
    is $decimate_data->[0]->{decimate_epoch}, '1479203115', "decimate_epoch is correct for first decimate data";
    is $decimate_data->[0]->{bid},            '108.285',    "bid is correct for first decimate data";
    is $decimate_data->[0]->{quote},          '108.286',    "quote is correct for first decimate data";
    is $decimate_data->[0]->{ask},            '108.288',    "ask is correct for first decimate data";
};

#sampledata2.csv has missing data for some interval.
my $data2 = data_from_csv('t/BOM/Market/DecimateCache/sampledata2.csv');

subtest "decimate_cache_insert_and_retrieve_with_missing_data" => sub {
    my $decimate_cache = BOM::Market::DataDecimate->new({market => 'forex'});

    ok $decimate_cache, "Instance has been created";

    my ($raw_key, $decimate_key) = map { $decimate_cache->_make_key('frxUSDJPY', $_) } (0 .. 1);

    my $redis = $decimate_cache->redis_write;
    $redis->zremrangebyscore($raw_key,      0, 1479203250);
    $redis->zremrangebyscore($decimate_key, 0, 1479203250);

    is scalar(@$data2), '128', "check number of test data";

    for (my $i = 0; $i <= 127; $i++) {
        $decimate_cache->data_cache_insert_raw($data2->[$i]);
    }

    my $data_out = $decimate_cache->_get_num_data_from_cache({
        symbol    => 'frxUSDJPY',
        num       => 128,
        end_epoch => 1479203250,
    });

    is scalar(@$data_out), '128', "retrieved 128 datas from cache";

    for (my $i = 1479203115; $i <= 1479203250 + 15; $i = $i + 15) {
        $decimate_cache->data_cache_insert_decimate('frxUSDJPY', $i);
    }

    my $decimate_data = $decimate_cache->_get_decimate_from_cache({
        symbol      => 'frxUSDJPY',
        start_epoch => 1479203101,
        end_epoch   => 1479203250,
    });

    is scalar(@$decimate_data), '10', "retrieved 10 decimated datas";

    is $decimate_data->[2]->{decimate_epoch}, '1479203145', "decimate_epoch is correct for the first missing interval";
    # let's check the value as well.
    # frxUSDJPY,1479203130,1479203130,108.272,108.278,108.284
    is $decimate_data->[2]->{epoch}, '1479203130', "epoch is correct for the first missing interval";
    is $decimate_data->[2]->{bid},   '108.272',    "bid is correct ";
    is $decimate_data->[2]->{quote}, '108.278',    "quote is correct";
    is $decimate_data->[2]->{ask},   '108.284',    "ask is correct";
    is $decimate_data->[2]->{count}, '0',          "count is correct.";

    my $latest_decimated_epoch = $decimate_cache->get_latest_tick_epoch('frxUSDJPY', 1, 1479203150, 1479203250);
    is $latest_decimated_epoch, 1479203250, "latest decimated epoch is correct.";

#simulate market close
    for (my $i = 1479203250 + 15; $i <= 1479203250 + 2000; $i = $i + 15) {
        $decimate_cache->data_cache_insert_decimate('frxUSDJPY', $i);
    }

    my $mkt_close_dec_data = $decimate_cache->_get_decimate_from_cache({
        symbol      => 'frxUSDJPY',
        start_epoch => 1479203101,
        end_epoch   => 1479203250 + 2000,
    });

    is $mkt_close_dec_data->[-1]->{decimate_epoch}, '1479205110', "decimate_epoch is correct for market close";
};

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

done_testing;
