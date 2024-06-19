#!/usr/bin/env perl

use strict;
use warnings;

use Pod::Usage;
use Getopt::Long;
use Log::Any::Adapter;
use Path::Tiny;

=head1 NAME

run_queue.pl - a generic queue and stream runner

=head1 SYNOPSIS

    run_queue.pl  --queue <queue_name> --stream <stream_name>

=head1 DESCRIPTION

This is designed as a generic stream runner for various streams, and can serve the same functionality for queues.

To make a new stream or queue, just pass in the stream\queue when calling this script from chef
To assign an event to the stream\queue, please specify it in BOM::Platform::Event::Emitter

=over 4

=head1 OPTIONS

One and only one option must be passed.

=head2 --queue NAME

The name of the queue in Redis that this will be listening to.

=head2 --streams NAME

Comma separated names of Redis streams that this will be listening to.

=head2 --category NAME

The type of worker, this controls the category of jobs that will be processed.

=cut

=back

=cut

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

GetOptions(
    'q|queue=s'          => \(my $queue   = undef),
    's|streams=s'        => \(my $streams = undef),
    'c|category=s'       => \(my $category),
    'json_log_file=s'    => \(my $json_log_file),
    'maximum_job_time=i' => \(my $maximum_job_time),
    'retry_interval=i'   => \(my $retry_interval),
    'l|log_level=s'      => \(my $log_level),
) or die;

#One and only one option must be passed
unless ($category && (!$queue != !$streams)) {
    pod2usage(1);
    die "Invalid Options Entered";
}

# Enable watchdog
$ENV{IO_ASYNC_WATCHDOG} = 1;
# Set watchdog interval
$ENV{IO_ASYNC_WATCHDOG_INTERVAL} = $maximum_job_time // 30;
# Listner consumes the above env variables to set watchdog timeout
require BOM::Event::Listener;

$json_log_file ||= '/var/log/deriv/' . path($0)->basename . '.json.log';
Log::Any::Adapter->import(
    qw(DERIV),
    log_level     => $log_level // $ENV{BOM_LOG_LEVEL} // 'info',
    json_log_file => $json_log_file,
);

my $listener = BOM::Event::Listener->new(
    queue            => $queue,
    streams          => [split ',', $streams],
    maximum_job_time => $maximum_job_time,
    category         => $category,
    retry_interval   => $retry_interval,
);

$listener->run;
