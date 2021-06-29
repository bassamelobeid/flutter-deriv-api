package BOM::Database::UserDB;

use strict;
use warnings;
use BOM::Database::Rose::DB;

sub rose_db {
    my %overrides  = @_;
    my $type       = delete $overrides{operation} // 'write';
    my $db_type    = $type eq 'replica' ? '_replica' : '';
    my $db_postfix = $ENV{DB_POSTFIX} // '';

    BOM::Database::Rose::DB->register_db(
        connect_options => {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0,
        },
        schema   => 'users',
        domain   => 'userdb',
        type     => $type,
        driver   => 'Pg',
        database => "userdb$db_type$db_postfix",
        port     => 6432,
        username => 'write',
        host     => '/var/run/postgresql',
        password => '',
        %overrides,
    );

    my $db = BOM::Database::Rose::DB->new_or_cached(
        domain => 'userdb',
        type   => $type,
    );

    $db->dbic->dbh->selectall_arrayref('SELECT audit.set_metadata(?::TEXT)', undef, $ENV{AUDIT_STAFF_NAME} // 'system');

    if ((BOM::Config->on_qa() or BOM::Config->on_ci()) and $type eq 'replica') {
        # Currently in QA/CI environments, the database is setup such that user is able
        # to write to replicas. Until we can more accurately mimic production setup,
        # we simulate this replica readonly behaviour as such:
        $db->dbic->dbh->do("SET default_transaction_read_only TO 'on'");
    }

    return $db;
}

1;
