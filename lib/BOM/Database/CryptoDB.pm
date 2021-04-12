package BOM::Database::CryptoDB;

use strict;
use warnings;
use BOM::Database::Rose::DB;

=head2 rose_db

Initialize a connection to the crypto DB and return it.

=cut

sub rose_db {
    my %overrides  = @_;
    my $db_postfix = $ENV{DB_POSTFIX} // '';
    my $operation  = $overrides{operation} ? $overrides{operation} : 'write';
    my $database   = 'crypto-' . $operation . $db_postfix;
    BOM::Database::Rose::DB->register_db(
        connect_options => {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0,
        },
        schema   => 'crypto',
        domain   => 'crypto',
        type     => $operation,
        driver   => 'Pg',
        database => $database,
        port     => 6432,
        username => 'write',
        host     => '/var/run/postgresql',
        password => '',
        %overrides,
    );

    return BOM::Database::Rose::DB->new_or_cached(
        domain => 'crypto',
        type   => $operation,
    );
}

1;
