package BOM::Platform::Script::MirrorBinaryUserId;

use 5.014;

use strict;
use warnings;
use BOM::Database::ClientDB;

use DBI;
use IO::Select;
use Try::Tiny;
use POSIX qw/strftime/;

our $DEBUG //= 1;    ## no critic
use constant TMOUT => 10;

STDERR->autoflush(1);

sub log_msg {
    my ($level, $msg) = @_;
    print STDERR strftime('%F %T', localtime), ": (PID $$) ", $msg, "\n"
        if $DEBUG >= $level;

    return;
}

sub userdb {
    my $ip = shift;

    # We can't use BOM::Database::UserDB here because it connects
    # through pgbouncer in transaction mode.
    return DBI->connect(
        "dbi:Pg:service=user01;application_name=MirrorBinaryUserId",
        undef, undef,
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        });
}

sub update_clientdb {
    my $row = shift;
    my ($binary_user_id, $loginid) = @$row;

    log_msg 2, "setting binary_user_id=" . ($binary_user_id // "NULL") . " for $loginid";
    return try {
        my $dbh = BOM::Database::ClientDB->new({
                client_loginid => $loginid,
            })->db->dbh;
        my @res = @{$dbh->selectcol_arrayref(<<'SQL', undef, $loginid, $binary_user_id)};
SELECT betonmarkets.update_binary_user_id(?::VARCHAR(12), ?::BIGINT)
SQL
        unless ($res[0]) {
            log_msg 0, "loginid $loginid has binary_user_id " . ($binary_user_id // "NULL") . " but does not exist in clientdb";
        }
        1;
    }
    catch {
        # Certain loginids (like MT...) don't have a clientdb.
        if (/^No such domain with the broker code /) {
            1;
        } else {
            0;
        }
    };
}

sub do_one {
    my $userdb = shift;

    my @brokers = @{$userdb->selectcol_arrayref('SELECT * FROM q.loginid_brokers()')};
    unless (@brokers) {
        log_msg 2, "queue is empty";
        return 0;
    }

    log_msg 2, "need to process these broker codes: @brokers";

    my $rows_removed = 0;
    for my $broker (@brokers) {
        # q.loginid_next() returns one row at a time
        $userdb->begin_work;
        my $rows = $userdb->selectall_arrayref('SELECT * FROM q.loginid_next(?)', undef, $broker);
        unless (@$rows) {
            $userdb->commit;
            log_msg 2, " ==> done with $broker";
            next;
        }

        if (update_clientdb $rows->[0]) {
            log_msg 2, " ==> clientdb updated";
            $rows_removed++;
            $userdb->commit;
        } else {
            log_msg 2, " ==> clientdb for broker $broker is not available -- rolling back";
            $userdb->rollback;
        }
    }
    log_msg 2, "$rows_removed rows removed from queue";
    return $rows_removed;
}

sub run {
    while (1) {
        try {
            my $dbh = userdb();
            my $sel = IO::Select->new;
            $sel->add($dbh->{pg_socket});

            $dbh->do('LISTEN "q.add_loginid"');
            $dbh->do('NOTIFY "q.add_loginid"');    # trigger first round

            log_msg 1, "started";

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
            log_msg 0, "saw exception: $_";
            sleep TMOUT;
        };
    }

    return;
}

1;
