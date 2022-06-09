use strict;
use warnings;
use Test::More;

use BOM::Test::CheckSyntax;

my $file = 'lib/BOM/Test/Rudderstack/Webserver.pm';
my $subs = BOM::Test::CheckSyntax::get_pm_subs($file);
ok !$subs, "cannot find subs for $file";

$file = 'lib/await.pm';
$subs = BOM::Test::CheckSyntax::get_pm_subs($file);
my $expcted_subs = {
    'wsapi_wait_for' => {
        'end'   => 63,
        'start' => 25
    },
    'AUTOLOAD' => {
        'end'   => 94,
        'start' => 68
    },
    'get_data' => {
        'end'   => 114,
        'start' => 96
    }};
is_deeply($subs, $expcted_subs, "check subs for $file");

done_testing();

