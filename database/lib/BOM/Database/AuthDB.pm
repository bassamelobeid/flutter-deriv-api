package BOM::Database::AuthDB;

use YAML::XS;
use feature "state";
use BOM::Database::Rose::DB;

sub rose_db {
    my %overrides = @_;
    state $config = YAML::XS::LoadFile('/etc/rmg/authdb.yml');
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
        database => 'auth',
        port     => $config->{port} || '5435',
        username => 'write',
        host     => $config->{ip},
        password => $config->{password},
        %overrides,
    );

    return BOM::Database::Rose::DB->new_or_cached(
        domain => 'authdb',
        type   => 'write',
    );
}

1;
