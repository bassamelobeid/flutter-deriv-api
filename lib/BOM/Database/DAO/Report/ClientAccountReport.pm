package BOM::Database::DAO::Report::ClientAccountReport;

use strict;
use warnings;

use BOM::Database::ClientDB;

sub get_logins_by_ip_and_login_age {
    my $args = shift;

    my $last_login_age = $args->{last_login_age} || 10;
    my $broker         = $args->{broker};
    my $ip             = $args->{ip};

    my $sql = q{
        SELECT client_loginid as loginid,login_date,login_environment
        FROM betonmarkets.login_history
        where login_successful is true and
        (current_date - date(login_date))< $1  and (login_environment like $2 or login_environment like $3) ORDER BY login_date DESC
    };

    my $result;
    my $dbh = BOM::Database::ClientDB->new({
            broker_code => $broker,
        })->db->dbh;

    my $select_handle = $dbh->prepare($sql);

    $select_handle->bind_param(1, $last_login_age);
    $select_handle->bind_param(2, 'IP=' . $ip . '%');
    $select_handle->bind_param(3, $ip . '%');

    if (not $select_handle->execute()) {
        Carp::croak("[$0] We souldn't be here!!! Exception didn't handle properly .");
    }

    $result = $select_handle->fetchall_arrayref({});

    # Here we select the unique loginids and last login_date
    my %loginids;
    foreach my $row (@$result) {
        if (not exists $loginids{$row->{loginid}}) {
            $loginids{$row->{loginid}} = $row;
        }
    }

    return values %loginids;
}

1;
