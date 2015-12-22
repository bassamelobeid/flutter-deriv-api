package BOM::Test::ResourceEvaluator;

=head1 NAME

BOM::Test::ResourceEvaluator

=head1 DESCRIPTION

This class will be used to test system memory before and after executing test case. This add checks for redis, authdb, couchdb, postgres connection before and after the test case execution and report accordingly

=head1 SYNOPSIS

    use BOM::Test::ResourceEvaluator::evaluate(\&function_to_execute);

=cut

use strict;
use warnings;

use JSON;
use JSON::Schema;
use File::Slurp;
use Test::Mojo;
use Test::Most;
use Devel::Gladiator qw(walk_arena arena_ref_counts arena_table);

sub evaluate {
    my $func = shift;

    # check for redis (Application)
    my $app_count = `netstat -nat | grep 6381 | grep EST |  wc -l`;
    $app_count = $app_count / 2;

    # check for redis (Local)
    my $local_count = `netstat -nat | grep 6379 | grep EST |  wc -l`;
    $local_count = $local_count / 2;

    my %dump1 = map { ("$_" => $_) } walk_arena();

    #start executing function now
    $func->();

    # take snapshot of memory after executing
    my $new_app_count = `netstat -nat | grep 6381 | grep EST |  wc -l`;
    $new_app_count = $new_app_count / 2;
    is $new_app_count, $app_count, 'Application redis connection is not leaked';

    my $new_local_count = `netstat -nat | grep 6379 | grep EST |  wc -l`;
    $new_local_count = $new_local_count / 2;
    is $new_local_count, $local_count, 'Local redis connection is not leaked';

    my %dump2 = map { $dump1{$_} ? () : ("$_" => $_) } walk_arena();
    use Devel::Peek;
    Dump \%dump2;

    return;
}

1;
