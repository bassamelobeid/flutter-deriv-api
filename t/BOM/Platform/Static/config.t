use Test::More;
use Test::FailWarnings;

my $file = '/etc/rmg/version';
open my $fh, '<', $file;
my @data = <$fh>;
close $fh;

open my $fh1, '>', $file;
print $fh1 "Some dummy data";
close $fh1;

require BOM::Platform::Static::Config;

ok(BOM::Platform::Static::Config::get_config()->{binary_static_hash}, "got some data even if version file contain dummy data");

is(BOM::Platform::Static::Config::get_static_path(),                 "/home/git/binary-com/binary-static/", 'Correct static path');
is(BOM::Platform::Static::Config::get_static_url(),                  "https://static.binary.com/",          'Correct static url');
is(BOM::Platform::Static::Config::get_customer_support_email(),      'support@binary.com',                  'Correct customer support email');
is(scalar @{BOM::Platform::Static::Config::get_display_languages()}, 13,                                    'Correct number of language');
is(
    BOM::Platform::Static::Config::get_config()->{binary_static_hash},
    BOM::Platform::Static::Config::get_config()->{binary_static_hash},
    'Static hash should be same even when requested multiple times'
);

open my $fh2, '>', $file;
foreach my $line (@data) {
    print $fh2 $line;
}
close $fh2;

done_testing();
