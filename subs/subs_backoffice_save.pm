use strict 'vars';
use open qw[ :encoding(UTF-8) ];

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
        close DATA;

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

    if (not -d "/var/log/fixedodds/staff/") {
        system("mkdir /var/log/fixedodds/staff/");
    }
    if (-s "/var/log/fixedodds/staff/$staff.difflog" > 500000) {
        system("mv /var/log/fixedodds/staff/$staff.difflog /var/log/fixedodds/staff/$staff.difflog.1");
    }

    if (open(DATA, ">>/var/log/fixedodds/staff/$staff.difflog")) {
        flock(DATA, 2);
        local $\ = "\n";
        print DATA "\n=============================================================";
        print DATA Date::Utility->new->datetime . " $loginID $staff $ENV{'REMOTE_ADDR'} newsize=" . (-s $overridefilename);
        print DATA "=============================================================";
        print DATA $diff;
        close DATA;
    } else {
        warn("Error: cannot open /var/log/fixedodds/staff/$staff.difflog to append $!");
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

    if ((-s "/var/log/fixedodds/fsave.completelog") > 3000000) {
        system("mv /var/log/fixedodds/fsave.completelog /var/log/fixedodds/fsave.completelog.1");
    }

    if (open(DATA, ">>/var/log/fixedodds/fsave.completelog")) {
        flock(DATA, 2);
        local $\ = "\n";
        print DATA "\n=============================================================";
        print DATA Date::Utility->new->datetime . " $loginID $staff $ENV{'REMOTE_ADDR'} newsize=" . (-s $overridefilename);
        print DATA "=============================================================";
        print DATA $diff;
        close DATA;
    } else {
        warn("Error: cannot open /var/log/fixedodds/fsave.completelog to append $!");
    }

}

1;
