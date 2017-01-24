use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use BOM::Backoffice;

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

    local *DATA;
    if (open DATA, ">>$overridefilename.difflog") {
        flock(DATA, 2);
        local $\ = "\n";
        print DATA "\n=============================================================";
        print DATA Date::Utility->new->datetime . " $loginID $staff $ENV{'REMOTE_ADDR'} newsize=" . (-s $overridefilename);
        print DATA "=============================================================";
        print DATA $diff;
        unless (close DATA) {
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

    local *DATA;

    my $log_dir = BOM::Backoffice::config->{log}->{staff_dir};
    if (not -d $log_dir) {
        system("mkdir $log_dir");
    }
    if (-s "$log_dir/$staff.difflog" > 500000) {
        system("mv $log_dir/$staff.difflog $log_dir/$staff.difflog.1");
    }

    if (open(DATA, ">>$log_dir/$staff.difflog")) {
        flock(DATA, 2);
        local $\ = "\n";
        print DATA "\n=============================================================";
        print DATA Date::Utility->new->datetime . " $loginID $staff $ENV{'REMOTE_ADDR'} newsize=" . (-s $overridefilename);
        print DATA "=============================================================";
        print DATA $diff;
        unless (close DATA) {
            warn("Error: cannot close $log_dir/$staff.difflog after append $!");
        }
    } else {
        warn("Error: cannot open $log_dir/$staff.difflog to append $!");
    }

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

    local *DATA;

    my $log = BOM::Backoffice::config->{log}->{fsave_complete};

    if ((-s $log) > 3000000) {
        system("mv $log $log.1");
    }

    if (open(DATA, ">>$log")) {
        flock(DATA, 2);
        local $\ = "\n";
        print DATA "\n=============================================================";
        print DATA Date::Utility->new->datetime . " $loginID $staff $ENV{'REMOTE_ADDR'} newsize=" . (-s $overridefilename);
        print DATA "=============================================================";
        print DATA $diff;
        unless (close DATA) {
            warn("Error: cannot close $log after append $!");
        }
    } else {
        warn("Error: cannot open $log to append $!");
    }

}

1;
