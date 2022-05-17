#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Loop;
use Getopt::Long;
use Log::Any::Adapter qw(Stderr), log_level => $ENV{BOM_LOG_LEVEL} // 'warning';

use Commission::Monitor;

my ($cfd_provider, $db_service, $redis_config);
GetOptions(
    "x|cfd_provider=s" => \$cfd_provider,
    "s|db_service=s"   => \$db_service,
    "c|redis_config=s" => \$redis_config,
) or die("Error in command line arguments\n");

my $loop    = IO::Async::Loop->new;
my $monitor = Commission::Monitor->new(
    cfd_provider => $cfd_provider,
    db_service   => $db_service,
    redis_config => $redis_config,
);

$loop->add($monitor);

$monitor->start->get();
