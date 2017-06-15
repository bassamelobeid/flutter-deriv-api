package BOM::Test::Time;
use strict;
use warnings;
our $mocked_time_file;
our $time_hires;
# we need real time_hires
BEGIN {
    unlink $mocked_time_file = '/tmp/mocked_time';
    $time_hires = \&Time::HiRes::time;
}

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

=head2 set_date

Change mocked date/time for current process.
Accepts anything that Date::Utility can handle - epoch time, 'YYYY-mm-dd HH:MM:SS', etc.
We store difference betweek mocked time and system time in $mocked_time_file.

=cut

# this block is needed unless upstream Test::MockTime::HiRes is fixed
# also update func proto &;@ -> $;@
BEGIN {
    no warnings 'redefine';    ## no critic (ProhibitNoWarnings)
    *Test::MockTime::time = sub () {
        return int(BOM::Test::Time::non_standard_time($time_hires));
    };

    sub non_standard_time {
        my $original = shift;
        return defined $Test::MockTime::fixed ? $Test::MockTime::fixed : $original->(@_) + $Test::MockTime::offset;
    }
}

sub set_date {
    my ($target_date) = @_;
    my $diff = Date::Utility->new($target_date)->epoch - $time_hires->();
    set_relative_time($diff);
    open my $fh, '>', $mocked_time_file;
    print $fh $diff;
    close $fh;
    return;
}

=head2 set_date_from_file

Set mocked time, as requested by another process.
We get difference of mocked and real time and set_relative_time.
If file is not present - do nothing.

=cut

sub set_date_from_file {
    open my $fh, '<', $mocked_time_file or return;
    my $diff = <$fh>;
    close $fh;
    set_relative_time($diff);
    return;
}

1;

