#!/usr/bin/env perl
use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;
use Test::NoWarnings;

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

    my $where = abs_path(dirname(__FILE__) . '/../..');
    note $where;
    find($wanted, $where);

    foreach my $filename (@yaml_files) {
        lives_ok { LoadFile($filename) } $filename . ' YAML parses.';
    }
};
