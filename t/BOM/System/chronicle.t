use strict;
use warnings;

use Test::More tests => 5;
use Test::NoWarnings;
use Time::HiRes;
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::System::Chronicle;

my $d = { sample1 => [1, 2, 3],
          sample2 => [4, 5, 6],
          sample3 => [7, 8, 9] };

my $first_save_epoch = time;
is BOM::System::Chronicle::set("vol_surface", "frxUSDJPY", $d), 1, "data is stored without problem";

my $d2 = BOM::System::Chronicle::get("vol_surface", "frxUSDJPY");
is_deeply $d, $d2, "data retrieval works";

sleep 1;

my $d3 = { xsample1 => [10, 20, 30],
          xsample2 => [40, 50, 60],
          xsample3 => [70, 80, 90] };

is BOM::System::Chronicle::set("vol_surface", "frxUSDJPY", $d3), 1, "new version of the data is stored without problem";

my $d4 = BOM::System::Chronicle::get("vol_surface", "frxUSDJPY");
is_deeply $d3, $d4, "data retrieval works for the new version";

