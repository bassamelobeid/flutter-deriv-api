use strict;
use warnings;

use Test::More tests => 3;
use Test::NoWarnings;
use Time::HiRes;

use BOM::System::Chronicle;


my $d = { sample1 => [1, 2, 3],
          sample2 => [4, 5, 6],
          sample3 => [7, 8, 9] };

is BOM::System::Chronicle::set("vol_surface", "frxUSDJPY", $d), 1, "date is stored without problem";

my $d2 = BOM::System::Chronicle::get("vol_surface", "frxUSDJPY");
is_deeply $d, $d2, "data retrieval works";




