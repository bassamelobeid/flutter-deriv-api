package BOM::Backoffice;

use warnings;
use strict;

use feature "state";
use YAML::XS;
use BOM::Backoffice::Request;
use Exporter 'import';
our @EXPORT_OK = qw(get_tmp_path_or_die);


sub config {
    state $config = YAML::XS::LoadFile('/etc/rmg/backoffice.yml');
    return $config;
}

#
# Here we handle situation caused by BO installations on multiple nodes with different functionalities
#
sub get_tmp_path_or_die {

    my $d = BOM::Backoffice::config->{directory}->{tmp};
    if ($_[0] and $_[0] eq 'gif') {
        $d = BOM::Backoffice::config->{directory}->{tmp_gif};
    }
    $d = $ENV{'TEST_TMPDIR'} if(defined $ENV{'TEST_TMPDIR'});
    if (not $d or $d eq '') {
        print "backoffice.yml directory.tmp undefined";
        BOM::Backoffice::Request::request_completed();
        exit 0;
    }
    if (not -d $d) {
        print "No such directory: $d. Maybe you're at wrong Backoffice";
        BOM::Backoffice::Request::request_completed();
        exit 0;
    }

    return $d;
}

1;

