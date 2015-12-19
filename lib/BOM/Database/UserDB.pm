package BOM::Database::UserDB;

use strict;
use warnings;
use BOM::Database::Rose::DB;

sub rose_db {
    my %overrides = @_;
    BOM::Database::Rose::DB->register_db(
        connect_options => {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0,
        },
        schema   => 'users',
        domain   => 'userdb',
        type     => 'write',
        driver   => 'Pg',
        database => 'userdb-write',
        port     => 6436,
        username => 'write',
        host     => '/var/run/postgresql' ,
        password => '',
        %overrides,
    );

    return BOM::Database::Rose::DB->new_or_cached(
        domain => 'userdb',
        type   => 'write',
    );
}

1;
