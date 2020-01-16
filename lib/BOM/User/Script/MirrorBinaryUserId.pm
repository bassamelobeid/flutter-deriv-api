package BOM::User::Script::MirrorBinaryUserId;

# Please read this first!
#
# The current implementation is very simple.
#
#  1. open a transaction in userdb
#  2. remove one item from the queue
#  3. update clientdb
#  4. commit transaction in userdb
#
# If the process dies somewhere after 1 the userdb transaction
# is rolled back and next time the same item will be removed.
# This works for this case because the clientdb update can be
# repeated without harm.
#
# Processing one item at a time should be good enough because
# changes in the association between binary users and loginids
# are rare.
# However, if it turns out it's not, you can run the daemon in
# multiple instances as long as we guarantee that loginids are
# only added to a binary user and never removed. If that is not
# given, the following can happen. A loginid is added and
# immediately removed. That creates 2 items in the queue. Now,
# process A picks the first item but gets delayed a little.
# Next, process B picks the second item, the loginid removal,
# and performs it. Then process A continues it's work and adds
# the binary_user_id to the client account. A typical race
# condition.
#
# If you are tempted to run this daemon in multiple instances,
# better change the design!

use 5.014;

use strict;
use warnings;
use BOM::Database::ClientDB;

use DBI;
use IO::Select;
use Syntax::Keyword::Try;
use POSIX qw/strftime/;

our $DEBUG;    ## no critic
use constant TMOUT => 10;

sub log_msg {
    my ($level, $msg) = @_;
    print STDERR strftime('%F %T', localtime), ": (PID $$) ", $msg, "\n"
        if (($DEBUG // 1) >= $level);

    return;
}

sub userdb {

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
    try {
        my $dbh = BOM::Database::ClientDB->new({
                client_loginid => $loginid,
            })->db->dbh;
        my @res = @{$dbh->selectcol_arrayref(<<'SQL', undef, $loginid, $binary_user_id)};
SELECT betonmarkets.update_binary_user_id(?::VARCHAR(12), ?::BIGINT)
SQL
        unless ($res[0]) {
            log_msg 0, "loginid $loginid has binary_user_id " . ($binary_user_id // "NULL") . " but does not exist in clientdb";
        }
        return 1;
    }
    catch {
        # Certain loginids (like MT...) don't have a clientdb.
        if ($@ =~ /^No such domain with the broker code /) {
            return 1;
        } else {
            return 0;
        }
    }
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

sub run_once {
    my $dbh = shift;

    # check if there is at least one notification
    # otherwise done
    do {
        # clear all notifications
        1 while $dbh->pg_notifies;

        # handle the queue until it becomes empty
        1 while do_one $dbh;
    } while ($dbh->pg_notifies);

    return;
}

sub run {
    log_msg 1, "started";

    while (1) {
        try {
            my $dbh = userdb();
            my $sel = IO::Select->new;
            $sel->add($dbh->{pg_socket});

            $dbh->do('LISTEN "q.add_loginid"');
            $dbh->do('NOTIFY "q.add_loginid"');    # trigger first round

            while (1) {
                run_once $dbh;
                $sel->can_read(TMOUT);
            }
        }
        catch {
            log_msg 0, "saw exception: $@";
            sleep TMOUT;
        }
    }

    return;
}

1;
