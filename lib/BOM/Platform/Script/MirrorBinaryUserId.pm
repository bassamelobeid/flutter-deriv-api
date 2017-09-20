package BOM::Platform::Script::MirrorBinaryUserId;

use 5.014;

use strict;
use warnings;
use BOM::Database::ClientDB;

use DBI;
# use DBD::Pg;
use IO::Select;
use Try::Tiny;

use constant TMOUT => 10;

sub userdb {
    my $ip = shift;
    return DBI->connect(
        "dbi:Pg:service=user01;application_name=MirrorBinaryUserId",
        undef,
        undef,
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        });
}

sub update_clientdb {
    my $row = shift;
    my ($binary_user_id, $loginid) = @$row;

    return try {
        my $dbh = BOM::Database::ClientDB->new({
            loginid => $loginid,
        })->db->dbh;
        my @res = @{$dbh->selectcol_arrayref(<<'SQL', undef, $loginid, $binary_user_id)};
SELECT betonmarkets.update_binary_user_id(?::VARCHAR(12), ?::BIGINT)
SQL
        warn "res = @res";
        unless ($res[0]) {
            warn "loginid $loginid has binary_user_id $binary_user_id but does not exist in clientdb\n";
        }
        1;
    }
    catch {
        0;
    };
}

sub do_one {
    my $userdb = shift;

    my @brokers = @{$userdb->selectcol_arrayref('SELECT * FROM q.loginid_brokers()')};

    my $rows_removed = 0;
    for my $broker (@brokers) {
        # q.loginid_next() returns one row at a time
        $userdb->begin_work;
        my @rows = $userdb->selectall_array('SELECT * FROM q.loginid_next(?)', undef, $broker);
        unless (@rows) {
            $userdb->commit;
            next;
        }

        if (update_clientdb $rows[0]) {
            $rows_removed++;
            $userdb->commit;
        } else {
            $userdb->rollback;
        }
    }
    return $rows_removed;
}

sub run {
    while (1) {
        try {
            my $dbh = userdb();
            my $sel = IO::Select->new;
            $sel->add($dbh->{pg_socket});

            $dbh->do("LISTEN q.add_loginid");
            $dbh->do("NOTIFY q.add_loginid"); # trigger first round

            while (1) {
                # check if there is at least one notification
                # otherwise wait
                $dbh->pg_notifies or $sel->can_read(TMOUT);

                # clear all notifications
                1 while $dbh->pg_notifies;

                # handle the queue until it becomes empty
                1 while do_one $dbh;
            }
        }
        catch {
            warn "$0 ($$): saw exception: $_";
            sleep TMOUT;
        };
    }
}

1;
