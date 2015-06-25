package BOM::Database::DAO::Client;

use strict;
use warnings;
use Carp;

use YAML::XS;
use Try::Tiny;
use BOM::Database::ClientDB;

sub get_all_self_exclusion_hashref_by_broker {
    my $broker = shift;

    if (not $broker) {
        croak 'Invalid parameter broker';
    }

    my $all_client_self_exclusion_ref;

    my $dbh = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db->dbh;

    my $select_client_self_exclusion_sql = q{SELECT * FROM betonmarkets.self_exclusion WHERE client_loginid LIKE $1};

    # get from client details table
    my $statement    = $dbh->prepare($select_client_self_exclusion_sql);
    my $broker_param = "$broker%";
    $statement->bind_param(1, $broker_param);
    $statement->execute();

    $all_client_self_exclusion_ref = $statement->fetchall_hashref('client_loginid');

    return $all_client_self_exclusion_ref;
}

sub get_client_login_history {
    my $client_loginid = shift;

    my $login_history_result;

    my $dbh = BOM::Database::ClientDB->new({
            client_loginid => $client_loginid,
        })->db->dbh;

    my $select_login_history_sql = q{
        SELECT login_environment, login_date, login_successful, login_action
        FROM betonmarkets.login_history
        WHERE client_loginid = $1
        ORDER BY login_date DESC
        LIMIT 100
    };

    my $login_history_statement = $dbh->prepare($select_login_history_sql);

    $login_history_statement->bind_param(1, $client_loginid);
    $login_history_statement->execute();
    $login_history_result = $login_history_statement->fetchall_arrayref({});

    return $login_history_result;
}

sub get_loginids_for_clients_with_expired_documents_arrayref {
    my $arg    = shift;
    my $broker = $arg->{'broker'};
    my $date   = $arg->{'date'};
    my $loginid_arrayref;

    my $dbh = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db->dbh;

    my $sql = q{
        SELECT DISTINCT c.loginid
        FROM betonmarkets.client AS c
        JOIN betonmarkets.client_authentication_document AS d
        ON d.client_loginid = c.loginid
        WHERE c.broker_code = $1
        GROUP BY c.loginid
        HAVING MAX(COALESCE(d.expiration_date, $2)) < $2
    };

    my $statement = $dbh->prepare($sql);
    $statement->bind_param(1, $broker);
    $statement->bind_param(2, $date->db_timestamp);
    $statement->execute();
    $loginid_arrayref = $statement->fetchall_arrayref;

    my @login_ids;

    foreach my $login_id (@{$loginid_arrayref}) {
        push @login_ids, $login_id->[0];
    }
    return \@login_ids;
}


1;
