package BOM::Test::Time;
use strict;
use warnings;
use Time::HiRes qw/clock_nanosleep TIMER_ABSTIME CLOCK_REALTIME/;
our $mocked_time_file;
our $time_hires;
# we need real time_hires
BEGIN {
    unlink $mocked_time_file = '/tmp/mocked_time';
    $time_hires = \&Time::HiRes::time;
}

use Test::MockTime qw( set_absolute_time );
use Test::MockTime::HiRes;
use Date::Utility;

use Exporter qw( import );
our @EXPORT_OK = qw( set_date set_date_from_file sleep_till_next_second );

=head

The logic on mocking time in RPC follows.

RPC.pm code can be called in two ways:

- through normal way - via bin/binary_rpc.pl. In this script we're checking
   if there is $ENV{MOCKTIME} defined. If it is - we load BOM::Test::Time and have mocked time.
   MOCKTIME is set only when services are started via BOM::Test::Service::BomRpc.

- in-process from bom-rpc tests. Here we already have BOM::Test::Time module loaded and don't have $ENV{MOCKTIME}


During handling RPC calls in bom-rpc code we check if BOM::Test::Time is loaded though checking %INC
and if yes, then set time to the requested one via set_date_from_file().


For IPC, when running test need to set time in another process, we update modified timestamp of $mocked_time_file in 
set_date(). This timestamp will be used during call to set_date_from_file() from child process. This file is deleted on start

=cut

=head2 set_date

Change mocked date/time for current process.
Accepts anything that Date::Utility can handle - epoch time, 'YYYY-mm-dd HH:MM:SS', etc.

=cut

sub set_date {
    my ($target_date) = @_;
    my $epoch = Date::Utility->new($target_date)->epoch;
    set_absolute_time($epoch);
    open my $fh, '>', $mocked_time_file;
    print $fh $epoch;
    close $fh;
    return;
}

=head2 set_date_from_file

Set mocked time, as requested by another process.
If file is not present - do nothing.

=cut

sub set_date_from_file {
    open my $fh, '<', $mocked_time_file or return;
    my $epoch = <$fh>;
    close $fh;
    set_absolute_time($epoch);
    return;
}

sub sleep_till_next_second {
    clock_nanosleep(CLOCK_REALTIME, (time + 1) * 1e9, TIMER_ABSTIME);
    return;
}

1;

