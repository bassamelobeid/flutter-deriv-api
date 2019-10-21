#!/etc/rmg/bin/perl
use strict;
use warnings;
use IO::Handle ();

use Getopt::Long 'GetOptions';
use Path::Tiny 'path';
use Pod::Usage 'pod2usage';
use Log::Any::Adapter;

use BOM::Pricing::Queue;

STDOUT->autoflush(1);
GetOptions
    'log-level=s' => \my $log_level,
    'pid-file=s'  => \my $pid_file,
    'help'        => \my $help;

pod2usage(1) if $help;
path($pid_file)->spew($$) if $pid_file;

Log::Any::Adapter->set('Stdout', log_level => $log_level // 'warn');

exit BOM::Pricing::Queue->new->run;

__END__

=encoding utf-8

=head1 NAME

price_queue.pl - Process queue for the BOM pricer daemon

=head1 SYNOPSIS

    price_queue.pl [--pid-file=/path/to/pid/file] [--log-level=warn] [--help]

=head1 OPTIONS

=over 8

=item B<--log-level=warn>

Set logging to a given level (e.g. C<warn>, C<info>, C<notice>, etc.)

=item B<--pid-file=/var/run/binary_pricer_queue.pid>

Record this daemon's PID to a given file.  Used primarily in test scripts.

=item B<--help>

Show this help message.

=back

=head1 DESCRIPTION

This script runs as a daemon to process the BOM pricer daemon's Redis queues.

=cut
