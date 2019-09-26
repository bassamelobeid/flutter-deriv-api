#!/usr/bin/env perl
use strict;
use warnings;

use IO::Async::Loop;
use IO::Async::Stream;
use Future::AsyncAwait;
use Log::Any qw($log);
use JSON::MaybeUTF8 qw(:v1);

use Finance::Underlying;
use BOM::RPC::Feed::Reader;

use Getopt::Long;

GetOptions(
    'l|log=s'      => \(my $log_level = 'info'),
    'p|port=i'     => \(my $port      = 8006),
    's|symbol=s'   => \(my $symbol    = 'frxUSDJPY'),
    't|time=i'     => \(my $start     = time - 100),
    'd|duration=i' => \(my $duration  = 5),
    'h|help'       => \(my $help),
) or die;

die <<"EOF" if ($help);
This script will act like a client and try to connect to feed_reader service, in order to request ticks.

usage: $0 OPTIONS
These options are available:
  -p, --port             Port that feed_reader service is listening on. (default: 8006)
  -s| --symbol           Symbol that you want to request for. (default: frxUSDJPY
  -t| --time             ticks tarting time. (default: before 100 seconds)
  -d| --duration         the duration from starting time. (default: 5)
  -l, --log LEVEL        Set the Log::Any logging level
  -h, --help             Show this message.
EOF

my $loop = IO::Async::Loop->new;
require Log::Any::Adapter;
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

my $underlying = Finance::Underlying->by_symbol($symbol)
    or die 'No underlying found for ' . $symbol;
my $pip_size = $underlying->pip_size or die 'invalid pip size for ' . $symbol;

(
    async sub {
        my $conn = await $loop->connect(
            addr => {
                family   => 'inet',
                socktype => "stream",
                port     => $port,
            },
        );

        $log->infof('Connected to %s', join ':', map { $conn->$_ } qw(sockhost sockport));
        $loop->add(
            my $stream = IO::Async::Stream->new(
                handle  => $conn,
                on_read => sub { },
            ));

        $log->debugf('Request from %d duration %d for %s', $start, $duration, $symbol);
        await $stream->write(
            pack 'N/a*',
            encode_json_utf8({
                    underlying => $symbol,
                    start      => $start,
                    duration   => $duration,
                }));
        my $read = await $stream->read_exactly(4);
        die "no return, check reader logs.\n" unless $read;
        my ($size) = unpack 'N1' => $read;
        $log->debugf('Expect %d bytes', $size);
        die 'way too much data' if $size > 4 * $duration;
        my $data      = await $stream->read_exactly($size);
        my @ticks     = unpack "(N1)*", $data;
        my $base_time = Time::Moment->from_epoch($start);

        for my $idx (0 .. $duration - 1) {
            my $tick = $ticks[$idx] or next;
            # multiply with pip_size to bring back original price
            # use pipsized_value to make sure price formatted.
            $tick = $underlying->pipsized_value($tick * $pip_size);
            $log->infof('%s %s %s', $symbol, $base_time->plus_seconds($idx)->strftime('%Y-%m-%d %H:%M:%S'), $tick,);
        }
    })->()->get;
