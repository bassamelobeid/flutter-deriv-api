#!/etc/rmg/bin/perl
use strict;
use warnings;

use Test::More;
use Test::Exception;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Find;
use YAML::XS qw(LoadFile);

subtest "Syntax check YAML files" => sub {
    my @yaml_files;
    my $wanted = sub {
        my $f = $File::Find::name;
        push @yaml_files, $f if ($f =~ /\.(yml|yaml)$/ and not $f =~ /invalid\.yml$/);
    };

    my $where = abs_path();
    note $where;
    find($wanted, $where);

    foreach my $filename (@yaml_files) {
        lives_ok { LoadFile($filename) } $filename . ' YAML valid.';
    }
};

done_testing;

