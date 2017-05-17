package BOM::Test::Time;
use strict;
use warnings;
use Time::HiRes;
use Test::MockTime qw( :all );
use Test::MockTime::HiRes;
use Date::Utility;

use Exporter qw( import );
our @EXPORT_OK = qw( set_date set_date_from_file );

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
    set_absolute_time($ts);
    return;
}

1;

