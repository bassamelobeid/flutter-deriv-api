package BOM::Backoffice::Config;

use warnings;
use strict;

use feature "state";
use YAML::XS;
use BOM::Backoffice::Request;
use BOM::Config;
use Exporter 'import';
our @EXPORT_OK = qw(get_tmp_path_or_die);

sub config {
    return BOM::Config::backoffice();
}

#
# Here we handle situation caused by BO installations on multiple nodes with different functionalities
#
sub get_tmp_path_or_die {
    my $type = shift;
    my $d    = config->{directory}->{tmp};
    if ($type and $type eq 'gif') {
        $d = config->{directory}->{tmp_gif};
    }
    $d = $ENV{'TEST_TMPDIR'} if defined $ENV{'TEST_TMPDIR'};
    unless ($d) {
        print "backoffice.yml directory.tmp undefined";
        BOM::Backoffice::Request::request_completed();
        exit 0;
    }
    unless (-d $d) {
        print "No such directory: $d. Maybe you're at wrong Backoffice";
        BOM::Backoffice::Request::request_completed();
        exit 0;
    }

    return $d;
}

1;
