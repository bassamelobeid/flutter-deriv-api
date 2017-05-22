use strict;
use warnings;

use Test::More;
use Test::Vars;

subtest 'unused vars' => sub {
    my %tested_files;
    # maybe need some order
    my @ordered_files = qw(
                            lib/BOM/Product/Contract.pm
                         );
    for my $file (@ordered_files, qx{git ls-files lib}) {
        chomp $file;
        if (-f $file and $file =~ /\.pm$/  and not exists $tested_files{$file}){
          vars_ok $file;
          $tested_files{$file} = 1;
        }
    }
    done_testing;
};
done_testing;

