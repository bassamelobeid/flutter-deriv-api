package BOM::Database::AuthDB;

use strict;
use warnings;
use BOM::Database::Rose::DB;

sub rose_db {
    my %overrides  = @_;
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    BOM::Database::Rose::DB->register_db(
        connect_options => {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0,
        },
        schema   => 'auth',
        domain   => 'authdb',
        type     => 'write',
        driver   => 'Pg',
        database => "authdb$db_postfix",
        port     => 6432,
        username => 'write',
        host     => '/var/run/postgresql',
        password => '',
        %overrides,
    );

    return BOM::Database::Rose::DB->new_or_cached(
        domain => 'authdb',
        type   => 'write',
    );
}

1;
