#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use BOM::Event::Listener;
use Log::Any::Adapter;
use Path::Tiny;

=head1 NAME

run_queue.pl - a generic queue runner

=head1 SYNOPSIS

    run_queue.pl  --queue <queue_name>

=head1 DESCRIPTION

This is designed as a generic queue runner for various queue.

To make a new queue, just pass in the queue when calling this script from chef
To assign an event to the queue, please specify it in BOM::Platform::Event::Emitter

=over 4

=head1 OPTIONS

=head2 --queue NAME

The name of the queue in Redis that this will be listening to.

=cut

=back

=cut

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

GetOptions(
    'q|queue=s'       => \my $queue,
    'json_log_file=s' => \my $json_log_file,
) or die;

$queue         ||= 'GENERIC_EVENTS_QUEUE';
$json_log_file ||= '/var/log/deriv/' . path($0)->basename . '.json.log';
Log::Any::Adapter->import(
    qw(DERIV),
    log_level     => $ENV{BOM_LOG_LEVEL} // 'info',
    json_log_file => $json_log_file
);

BOM::Event::Listener->new(queue => $queue)->run;
