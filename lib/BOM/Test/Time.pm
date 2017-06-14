package BOM::Test::Time;
use strict;
use warnings;
use Time::HiRes;
use Test::MockTime qw( :all );
use Test::MockTime::HiRes;
use Date::Utility;

use Exporter qw( import );
our @EXPORT_OK = qw( set_date set_date_from_file );

=head

The logic on mocking time in RPC and PricingRPC follows.

RPC.pm code can be called in two ways:

- through normal way - via bin/binary_rpc.pl or binary_pricing_rpc.pl. In theese scripts we're checking
   if there is $ENV{MOCKTIME} defined. If it is - we load BOM::Test::Time and have mocked time.
   MOCKTIME is set only when services are started via BOM::Test::Service::BomRpc or PricingRpc.

- in-process from bom-rpc tests. Here we already have BOM::Test::Time module loaded and don't have $ENV{MOCKTIME}


During handling RPC calls in bom-rpc and bom-pricing code we check if BOM::Test::Time is loaded though checking %INC
and if yes, then set time to the requested one via set_date_from_file().


For IPC, when running test need to set time in another process, we update modified timestamp of $mocked_time_file in 
set_date(). This timestamp will be used during call to set_date_from_file() from child process. This file is deleted on start

=cut

our $mocked_time_file;

BEGIN {
    unlink $mocked_time_file = '/tmp/mocked_time';
}

=head2 set_date

Change mocked date/time for current process.
Accepts anything that Date::Utility can handle - epoch time, 'YYYY-mm-dd HH:MM:SS', etc.
We also store system time and mocked time in access time and modification time of $mocked_time_file metadata.

=cut

sub set_date {
    my ($target_date) = @_;
    my $epoch = Date::Utility->new($target_date)->epoch;
    set_absolute_time($epoch);
    unless (-e $mocked_time_file) {
        open my $fh, '>>', $mocked_time_file;
        close $fh;
    }
    utime(CORE::time, $epoch, $mocked_time_file);

    return;
}

=head2 set_date_from_file

Set mocked time, as requested by another process.
We get both access and modification time and set_relative_time by their difference.
This will save us in case there were few seconds between set_date() and set-date_from_file() calls.
If file is not present - do nothing.

=cut

sub set_date_from_file {
    my ($atime, $mtime) = ((stat($mocked_time_file)))[8, 9];
    return unless $atime;
    set_relative_time($mtime - $atime);
    return;
}

1;

