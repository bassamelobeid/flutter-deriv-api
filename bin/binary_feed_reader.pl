#!/usr/bin/env perl
use strict;
use warnings;

use BOM::RPC::Feed::Reader;
use Getopt::Long;
use IO::Async::Loop;
use Log::Any qw($log);
use Path::Tiny;

STDOUT->autoflush(1);

GetOptions(
    'l|log=s'          => \(my $log_level    = 'info'),
    'b|base=s'         => \(my $base_path    = '/var/lib/binary/rpc_feed'),
    'p|port=i'         => \(my $port         = 8006),
    'n|service-name=s' => \(my $service_name = 'local_feed_reader_service'),
    'h|help'           => \(my $help),
) or die;

die 'Feed path ' . $base_path . ' does not exist, check --help for more info' unless path($base_path)->is_dir;

die <<"EOF" if ($help);
This will run an instance from BOM::RPC::Feed::Reader which will be able to stream feed, by reading ticks from feed files in base, and wwill be listening on the port selected.

usage: $0 OPTIONS
These options are available:
  -b, --base             Base path where feed files to read/stream will be located . (default: /var/lib/binary/rpc_feed)
  -p, --port             Port that this service will be listening on. (default: 8006)
  -l, --log LEVEL        Set the Log::Any logging level
  -n, --service-name     name the process will have in process list.
  -h, --help             Show this message.
EOF

require Log::Any::Adapter;
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

my $loop = IO::Async::Loop->new;

$log->infof("Running as %s, Now = %s", $service_name, time);
local $0 = $service_name;

$loop->add(
    my $reader = BOM::RPC::Feed::Reader->new(
        base_path => $base_path,
        port      => $port,
    ));
my ($listener) = $reader->listener->get;

my $actual_port = $listener->read_handle->sockport;
$log->infof('Serving feed files from %s on port %d', $base_path, $actual_port);

$loop->run;
