package BOM::Database::UserDB;

use YAML::XS;
use feature "state";

sub rose_db {
    my %overrides = @_;
    state $config = YAML::XS::LoadFile('/etc/rmg/userdb.yml');
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
        database => 'users',
        port     => '5436',
        username => 'write',
        host     => $config->{ip},
        password => $config->{password},
        %overrides,
    );

    return BOM::Database::Rose::DB->new_or_cached(
        domain => 'userdb',
        type   => 'write',
    );
}

1;
