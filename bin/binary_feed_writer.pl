#!/etc/rmg/bin/perl
use strict;
use warnings;

no indirect;

use BOM::RPC::Feed::Writer;
use BOM::Config;
use Finance::Asset;
use IO::Async::Loop;
use Path::Tiny;
use Syntax::Keyword::Try;
use Getopt::Long;

use Log::Any qw($log);

STDOUT->autoflush(1);

GetOptions(
    'l|log=s'          => \(my $log_level      = 'info'),
    'b|base=s'         => \(my $base_path      = '/var/lib/binary/rpc_feed'),
    'r|redis=s'        => \(my $redis          = 'master-read'),
    't|start=s'        => \(my $start_override = undef),
    's|symbols=s'      => \(my $symbols_list   = ''),
    'n|service-name=s' => \(my $service_name   = 'local_feed_writer_service'),
    'h|help'           => \(my $help),
) or die;

die 'Feed path ' . $base_path . ' does not exist. Check with --help option for more information' unless path($base_path)->is_dir;

die <<"EOF" if ($help);
This will run an instance from BOM::RPC::Feed::Writer streams tick data from the database and feed client to local fixed-record files.

usage: $0 OPTIONS
These options are available:
  -b, --base             Base path where feed files will be written to . (default: /var/lib/binary/rpc_feed)
  -r, --redis            feed Redis that is going to be subscribed to. In order to get the latest ticks. (default: 'master-read')
  -t, --start            starting when to get ticks, default will be statrting from the oldest tick in database.
  -s, --symbol           which symbols to be written, default is all available symbols.
  -n, --service-name     name the process will have in process list.
  -l, --log LEVEL        Set the Log::Any logging level
  -h, --help             Show this message.
EOF

require Log::Any::Adapter;
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

my $loop = IO::Async::Loop->new;
my @symbols = $symbols_list ? split(/,/, $symbols_list) : Finance::Asset->symbols;

$log->infof("Running as %s at %s", $service_name, time);
$0 = $service_name;

try {
    $loop->add(
        my $writer = BOM::RPC::Feed::Writer->new(
            db_connection_count => 2,
            feeddb_uri          => BOM::Config::feed_rpc()->{writer}->{feeddb_uri},
            base_path           => $base_path,
            redis_source        => $redis,
            start_override      => $start_override,
            symbols             => \@symbols,
        )
    );
    $writer->run->get;
    $loop->run;
} catch {
    $log->errorf("%s error: %s at %d", $service_name, $@, time);
}
$log->infof('%s finished at %d', $service_name, time);

