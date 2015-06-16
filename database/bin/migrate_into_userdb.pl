#!/usr/bin/perl

use strict;
use warnings;

# su nobody
unless ($>) {
    $) = (getgrnam('nogroup'))[2];
    $> = (getpwnam('nobody'))[2];
}

use DBI;
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();
use BOM::Database::ClientDB;

my $select_users = q{
    SELECT * FROM users.binary_user
};

my $insert_user = q{
    INSERT INTO users.binary_user
        (email, password)
        VALUES (?, ?)
    RETURNING id
};

my $insert_loginid = q{
    INSERT INTO users.loginid
        (loginid, binary_user_id)
        VALUES (?, ?)
};

my $insert_pwd_map = q{
    INSERT INTO users.email_password_map
        (email, password_from)
        VALUES (?, ?)
};

my $update_user = q{
    UPDATE users.binary_user
        SET password = ?
    WHERE email = ?
};

my $update_pwd_map = q{
    UPDATE users.email_password_map
        SET password_from = ?
    WHERE email = ?
};

my $status_query = q{
    WITH clients as (
        SELECT
            email,
            count(*),
            string_agg(loginid, ',') as loginid
        FROM
            betonmarkets.client
        WHERE
            broker_code IN ('CR', 'MX', 'MLT', 'VRTC')
        GROUP BY 1
        HAVING count(*) ##_COUNT_##
    )

    SELECT *
    FROM
        (
            SELECT loginid, email, client_password
            FROM betonmarkets.client
            WHERE
                email IN (SELECT email FROM clients)
                AND broker_code IN ('CR', 'MX', 'MLT', 'VRTC')
        ) c
        LEFT JOIN (
            SELECT
                client_loginid,
                status_code as status
            FROM
                betonmarkets.client_status
            WHERE
                status_code = 'disabled'
        ) s
            ON c.loginid = s.client_loginid
        LEFT JOIN transaction.account a
            ON c.loginid = a.client_loginid AND a.is_default = TRUE
};

my $userdb = 'localhost';
my $pwd = 'letmein';
my $user_dbh = DBI->connect("dbi:Pg:dbname=users;host=$userdb;port=5436", 'postgres', $pwd) or croak $DBI::errstr;
$user_dbh->{AutoCommit} = 0;

my $insert_user_sth = $user_dbh->prepare($insert_user);
my $insert_loginid_sth = $user_dbh->prepare($insert_loginid);
my $pwd_map_sth = $user_dbh->prepare($insert_pwd_map);
my $update_user_sth = $user_dbh->prepare($update_user);
my $update_pwd_map_sth = $user_dbh->prepare($update_pwd_map);



foreach my $broker_code ('VRTC', 'CR', 'MX', 'MLT') {
    my $existing_users = $user_dbh->selectall_hashref($select_users, 'email');

    print "broker [$broker_code]\n";
    print "existing users count[" . scalar(keys %{$existing_users}) ."]\n";

    my $broker_dbh = BOM::Database::ClientDB->new({
            broker_code => $broker_code,
            operation   => 'replica',
        })->db->dbh;

    #### multiple loginids
    my $multiple_query = q{
        SELECT
            email,
            count(*),
            string_agg(loginid, ',') as loginid
        FROM
            betonmarkets.client
        WHERE
            broker_code IN ('CR', 'MX', 'MLT', 'VRTC')
        GROUP BY 1
        HAVING count(*) > 1
    };
    my $multiple_clients = $broker_dbh->selectall_hashref($multiple_query, 'email');

    print "multiple clients count[" . scalar(keys %{$multiple_clients}) ."]\n";

    my $multiple_sql = $status_query;
    $multiple_sql =~ s/##_COUNT_##/> 1/g;
    my $clients_details = $broker_dbh->selectall_hashref($multiple_sql, 'loginid');

    EMAIL:
    foreach my $email (keys %{$multiple_clients}) {
        if (not $email or $email eq '') {
            next;
        }

        my @loginids = split(',', $multiple_clients->{$email}->{loginid});

        # choose default pwd from loginid, based on:
        #       max balance
        #       loginid not disabled

        my $active_loginid;
        my $max_bal = 0;

        foreach my $loginid (@loginids) {
            my $bal = $clients_details->{$loginid}->{balance};

            my $status = '';
            $status = $clients_details->{$loginid}->{status} if (defined $clients_details->{$loginid}->{status});

            if ($bal and $bal > $max_bal and $status ne 'disabled') {
                $max_bal = $bal;
                $active_loginid = $loginid;
            }
        }

        # insert or update user db
        my $user_id;
        if (not exists $existing_users->{$email}) {
            # no active loginid, pick 1st one
            $active_loginid = $loginids[0] if not $active_loginid;
            my $password = $clients_details->{$active_loginid}->{client_password};

            $insert_user_sth->execute($email, $password);
            my @id = $insert_user_sth->fetchrow_array();
            $user_id = $id[0];

            # tmp table: indicate pwd from which loginid
            $pwd_map_sth->execute($email, $active_loginid);
        } else {
            $user_id = $existing_users->{$email}->{id};

            if ($active_loginid) {
                my $password = $clients_details->{$active_loginid}->{client_password};
                $update_user_sth->execute($password, $email);
                $update_pwd_map_sth->execute($active_loginid, $email);
            }
        }

        foreach my $loginid (@loginids) {
            $insert_loginid_sth->execute($loginid, $user_id);
        }
    }

    #### single loginid
    my $single_sql = $status_query;
    $single_sql =~ s/##_COUNT_##/= 1/g;
    my $single_clients = $broker_dbh->selectall_hashref($single_sql, 'email');

    print "single client count[" . scalar(keys %{$single_clients}) ."]\n";

    foreach my $email (keys %{$single_clients}) {
        my $details = $single_clients->{$email};
        my $loginid = $details->{loginid};
        my $password = $details->{client_password};

        # insert or update user db
        my $user_id;
        if (not exists $existing_users->{$email}) {
            $insert_user_sth->execute($email, $password);
            my @id = $insert_user_sth->fetchrow_array();
            $user_id = $id[0];

            # tmp table: indicate pwd from which loginid
            $pwd_map_sth->execute($email, $loginid);
        } else {
            $user_id = $existing_users->{$email}->{id};

            my $bal = $details->{balance};
            my $status = '';
            $status = $details->{status} if (defined $details->{status});

            if ($bal and $bal > 0 and $status ne 'disabled') {
                my $password = $details->{client_password};
                $update_user_sth->execute($password, $email);
                $update_pwd_map_sth->execute($loginid, $email);
            }
        }

        $insert_loginid_sth->execute($loginid, $user_id);
    }

    $broker_dbh->disconnect;
    $user_dbh->commit;
}


1;    # in case you want to use it as a console. :-)
