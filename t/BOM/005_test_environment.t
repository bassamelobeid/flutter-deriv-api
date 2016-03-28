use strict;

use Data::Dumper;
use File::Find::Rule;
use Cwd;

use Test::More;

subtest "BOM tests must use any BOM::Test module before other BOM modules, check tests in t/BOM" => sub {
    for my $t_filename (sort File::Find::Rule->file->name(qr/\.t$/)->in(Cwd::abs_path . '/t/BOM')) {
        open my $fh, $t_filename or die $!;
        my $first_bom_module;
        while (<$fh>) {
            last if ($first_bom_module) = $_ =~ /^use (BOM::.+);/; ## no struct test
        }
        close $fh;
        ok !$first_bom_module || $first_bom_module =~ /BOM::Test/, $t_filename;
    }
};

done_testing;
