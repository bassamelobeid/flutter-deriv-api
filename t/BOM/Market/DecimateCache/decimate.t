
use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestRedis;

use BOM::MarketData qw(create_underlying);
use BOM::Test::Data::Utility::FeedTestDatabase qw( :init );

use BOM::Market::DecimateCache;
use Text::CSV;

#add test case here

my $data = data_from_csv('t/BOM/Market/DecimateCache/sampledata.csv');

subtest "decimate_cache_insert_and_retrieve" => sub {
    my $decimate_cache = BOM::Market::DecimateCache->new();

    ok $decimate_cache, "DecimateCache instance has been created";  
   
    is scalar(@$data), '142', "check number of test data";      

    for (my $i = 0; $i <= 141; $i++) {
        $decimate_cache->data_cache_insert_raw($data->[$i]);
    }

    my $data_out = $decimate_cache->data_cache_get_num_data({
        symbol => 'USDJPY',
        num    => 142,
    });

    is scalar(@$data_out), '142', "retrieved 142 datas from cache";

#test insert_decimate
# try get all decimated datas
# last data in our sample
# USDJPY,1479203250,1479203250,108.254,108.256,108.257
    for (my $i = 1479203115; $i <= 1479203250; $i=$i+15) {
	$decimate_cache->data_cache_insert_decimate('USDJPY', $i);
    }

    my $decimate_data = $decimate_cache->decimate_cache_get({
        symbol      => 'USDJPY',
        start_epoch => 1479203101,
        end_epoch   => 1479203250,
    });

    is scalar(@$decimate_data), '10', "retrieved 10 decimated datas";    

};

my $data2 = data_from_csv('t/BOM/Market/DecimateCache/sampledata2.csv');

subtest "decimate_cache_insert_and_retrieve_with_missing_data" => sub {
    my $decimate_cache = BOM::Market::DecimateCache->new();

    ok $decimate_cache, "DecimateCache instance has been created";

    my ($raw_key, $decimate_key) = map { $decimate_cache->_make_key('USDJPY', $_) } (0 .. 1);

    my $redis = $decimate_cache->redis_write;
    $redis->zremrangebyscore($raw_key, 0, 1479203250);
    $redis->zremrangebyscore($decimate_key,   0, 1479203250);    

    is scalar(@$data2), '128', "check number of test data";

    for (my $i = 0; $i <= 127; $i++) {
        $decimate_cache->data_cache_insert_raw($data2->[$i]);
    }

    my $data_out = $decimate_cache->data_cache_get_num_data({
        symbol => 'USDJPY',
        num    => 128,
    });

    is scalar(@$data_out), '128', "retrieved 128 datas from cache";

    for (my $i = 1479203115; $i <= 1479203250; $i=$i+15) {
        $decimate_cache->data_cache_insert_decimate('USDJPY', $i);
    }

    my $decimate_data = $decimate_cache->decimate_cache_get({
        symbol      => 'USDJPY',
        start_epoch => 1479203101,
        end_epoch   => 1479203250,
    });

    is scalar(@$decimate_data), '10', "retrieved 10 decimated datas";
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
