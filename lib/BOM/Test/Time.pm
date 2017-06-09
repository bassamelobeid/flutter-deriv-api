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

=cut



our $mocked_time_file = '/tmp/mocked_time';

# Change system date/time. Accepts anything that Date::Utility
# can handle - epoch time, 'YYYY-mm-dd HH:MM:SS', etc.
#
# here we set mocked time for current process
sub set_date {
    my ($target_date) = @_;
    my $date = Date::Utility->new($target_date);
    set_absolute_time($date->epoch);
    while (!utime($date->epoch, $date->epoch, $mocked_time_file)) {
        open my $fh, '>>', $mocked_time_file;
        close $fh;
    }
    return;
}

# and here we set mocked time, as requested by another process
sub set_date_from_file {
    my $ts = (stat($mocked_time_file))[9];
    return unless $ts;
    set_absolute_time($ts);
    return;
}

1;

