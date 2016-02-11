use Test::More;
use Test::FailWarnings;

my $file = '/etc/rmg/version';
open my $fh, '<', $file;
my @data = <$fh>;
close $fh;

my $commit_id = "1d929a7";
open my $fh1, '>', $file;
print $fh1 "repository: environment-manifests-www2\n";
print $fh1 "commit: $commit_id\n";
close $fh1;

require BOM::Platform::Static::Config;

is(BOM::Platform::Static::Config::get_config()->{binary_static_hash}, $commit_id, "correct commit id");

open my $fh2, '>', $file;
foreach my $line (@data) {
    print $fh2 $line;
}
close $fh2;

done_testing();
