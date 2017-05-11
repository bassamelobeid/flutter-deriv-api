package BOM::Test::Suite;
use strict;
use warnings;
use Test::MockTime qw( :all );
use Date::Utility;

#
# simple module to provide mocked time
#


our $mocked_time_file = '/tmp/mocked_time';

# Change system date/time. Accepts anything that Date::Utility
# can handle - epoch time, 'YYYY-mm-dd HH:MM:SS', etc.
#
# here we set mocked time for current process
sub set_date {
    my ($target_date) = @_;
    my $date = Date::Utility->new($target_date);
    set_fixed_time($date->epoch);
    while (!utime($date->epoch, $date->epoch, $mocked_time_file)) {
        open my $fh, '>>', $mocked_time_file;
        close $fh;
    }
    return;
}

# and here we set mocked time, as requested by another process
sub set_date_from_file {
    my $ts = -M $mocked_time_file;
    set_fixed_time($ts);
    return;
}

1;

