## no critic (RequireExplicitPackage)
use strict;
use warnings;

use open qw[ :encoding(UTF-8) ];
use BOM::Backoffice::Config;

#####################################################################
# Purpose    : Save difference to difflog
# Returns    : 1 / 0
# Parameters : Hash reference with keys:
#              'overridefilename' => $overridefilename,
#              'loginID'          => $loginID,
#              'staff'            => $staff,
#              'diff'             => $diff,
#####################################################################
sub save_difflog {
    my $arg_ref          = shift;
    my $overridefilename = $arg_ref->{'overridefilename'};
    my $loginID          = $arg_ref->{'loginID'};
    my $staff            = $arg_ref->{'staff'};
    my $diff             = $arg_ref->{'diff'};

    if (open my $data, ">>", "$overridefilename.difflog") {
        flock($data, 2);
        local $\ = "\n";
        print $data "\n=============================================================";
        print $data Date::Utility->new->datetime . " $loginID $staff $ENV{'REMOTE_ADDR'} newsize=" . (-s $overridefilename);
        print $data "=============================================================";
        print $data $diff;
        unless (close $data) {
            warn("Error: cannot close $overridefilename.difflog after append $!");
            return 0;
        }

        return 1;
    } else {
        warn("Error: cannot open $overridefilename.difflog to append $!");
        return 0;
    }

}

#####################################################################
# Purpose    : Log the change to
#				"/var/log/fixedodds/staff/$staff.difflog"
# Returns    : N / A
# Parameters : Hash reference with keys
#				'overridefilename' => $overridefilename,
#				'loginID'          => $loginID,
#				'staff'            => $staff,
#				'diff'             => $diff,
#####################################################################
sub save_log_staff_difflog {
    my $arg_ref          = shift;
    my $overridefilename = $arg_ref->{'overridefilename'};
    my $loginID          = $arg_ref->{'loginID'};
    my $staff            = $arg_ref->{'staff'};
    my $diff             = $arg_ref->{'diff'};

    my $log_dir = BOM::Backoffice::Config::config()->{log}->{staff_dir};
    if (not -d $log_dir) {
        system("mkdir $log_dir");
    }

    my $size = -s "$log_dir/$staff.difflog";

    if (defined $size and $size > 500000) {
        system("mv $log_dir/$staff.difflog $log_dir/$staff.difflog.1");
    }

    if (open(my $data, ">>", "$log_dir/$staff.difflog")) {
        flock($data, 2);
        local $\ = "\n";
        print $data "\n=============================================================";
        print $data Date::Utility->new->datetime . " $loginID $staff $ENV{'REMOTE_ADDR'} newsize=" . (-s $overridefilename);
        print $data "=============================================================";
        print $data $diff;
        unless (close $data) {
            warn("Error: cannot close $log_dir/$staff.difflog after append $!");
        }
    } else {
        warn("Error: cannot open $log_dir/$staff.difflog to append $!");
    }

    return;
}

#####################################################################
# Purpose    : Log the change to
#				"/var/log/fixedodds/fsave.completelog"
# Returns    : N / A
# Parameters : Hash reference with keys
#				'overridefilename' => $overridefilename,
#				'loginID'          => $loginID,
#				'staff'            => $staff,
#				'diff'             => $diff,
#####################################################################
sub save_log_save_complete_log {
    my $arg_ref          = shift;
    my $overridefilename = $arg_ref->{'overridefilename'};
    my $loginID          = $arg_ref->{'loginID'};
    my $staff            = $arg_ref->{'staff'};
    my $diff             = $arg_ref->{'diff'};

    my $log = BOM::Backoffice::Config::config()->{log}->{fsave_complete};

    if ((-s $log) > 3000000) {
        system("mv $log $log.1");
    }

    if (open(my $data, ">>", "$log")) {
        flock($data, 2);
        local $\ = "\n";
        print $data "\n=============================================================";
        print $data Date::Utility->new->datetime . " $loginID $staff $ENV{'REMOTE_ADDR'} newsize=" . (-s $overridefilename);
        print $data "=============================================================";
        print $data $diff;
        unless (close $data) {
            warn("Error: cannot close $log after append $!");
        }
    } else {
        warn("Error: cannot open $log to append $!");
    }
    return;
}

1;
