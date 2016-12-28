
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

#add test case here

#my $datas = datas_from_csv('t/sampledata.csv');

subtest "decimate_cache_insert_and_retrieve" => sub {
    my $decimate_cache = BOM::Market::DecimateCache->new();

    ok $decimate_cache, "DecimateCache instance has been created";  
   
      
};

sub datas_from_csv {
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
