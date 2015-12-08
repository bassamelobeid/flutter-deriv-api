use strict;
use warnings;

use Test::MockTime qw(:all);
use Test::More tests => 6;
use Test::Exception;
use Test::NoWarnings;
use Time::HiRes;
use Time::Local ();
use BOM::Test::Data::Utility::UnitTestCouchDB qw(:init);
use BOM::System::Chronicle;
use Date::Utility;

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

subtest 'set for a specific date' => sub {
    my $now = Date::Utility->new;
    $d->{sample4} = 'something';
    my $ten_minutes_ago = $now->minus_time_interval('10m');
    lives_ok {
        set_absolute_time($ten_minutes_ago->epoch);
        ok BOM::System::Chronicle::set("vol_surface", "frxUSDJPY", $d), 'saved';
        restore_time;

        my $d = BOM::System::Chronicle::get_for('vol_surface', 'frxUSDJPY', $ten_minutes_ago);
        is $d->{sample4}, 'something', 'data retrieved';
    } 'save and fetch from postgres chronicle';
};
