package BOM::Test::Data::Utility::TestDatabaseSetup;

use Moose::Role;
use Carp;
use DBI;
use File::Slurp;
use Try::Tiny;
use DBIx::Migration;
use BOM::Test;

use constant {
    SNAPSHOT_DIR => '/tmp/test-db-snapshots',
    PG_DIR       => '/usr/lib/postgresql',
    PSQL         => '/etc/rmg/bin/psql',
};

requires '_db_name', '_post_import_operations', '_build__connection_parameters', '_db_migrations_dir';

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub prepare_unit_test_database {
    my $self = shift;

    try {
        return if $self->_restore_snapshot;
        $self->_migrate_changesets;
        $self->_post_import_operations;
        $self->_create_snapshot;
    }
    catch {
        Carp::croak '[' . $0 . '] preparing unit test database failed. ' . $_;
    };
    return 1;
}

has '_connection_parameters' => (
    is         => 'ro',
    lazy_build => 1,
);

sub dsn {
    my $self                = shift;
    my $db                  = shift || $self->_db_name;
    my $connection_settings = $self->_connection_parameters;
    my $port                = $db eq 'pgbouncer' ? $connection_settings->{pgbouncer_port} : $connection_settings->{port};
    my $host                = $db eq 'pgbouncer' ? '/var/run/postgresql' : $connection_settings->{host};
    return 'dbi:Pg:dbname=' . $db . ';host=' . $host . ';port=' . $port;
}

sub db_handler {
    my $self     = shift;
    my $db       = shift;
    my $password = ($db // '') eq 'pgbouncer' ? '' : $self->_connection_parameters->{'password'};
    my $dbh      = DBI->connect($self->dsn($db), 'postgres', $password)
        or croak $DBI::errstr;
    return $dbh;
}

sub _migrate_changesets {
    my $self = shift;

    my $dbh = $self->db_handler('postgres');
    $dbh->{RaiseError} = 1;    # die if we cannot perform any of the operations below
    $dbh->{PrintError} = 0;

    # first teminate all other connections
    my $pooler = $self->db_handler('pgbouncer');
    $pooler->{RaiseError}        = 1;
    $pooler->{pg_server_prepare} = 0;

    my $b_db;
    my @bouncer_dbs;

    my $sth = $pooler->prepare('SHOW DATABASES');
    $sth->execute;

    while (my $row = $sth->fetchrow_hashref) {
        if ($row->{database} eq $self->_db_name) {
            $b_db = $row->{name};
            push @bouncer_dbs, $b_db;

            try {
                $pooler->do('DISABLE "' . $b_db . '"');
                #$pooler->do('PAUSE "'.$b_db.'"');
            }
            catch {
                print "[pgbouncer] DISABLE $b_db error [$_]";
            };

            try {
                $pooler->do('KILL "' . $b_db . '"');
            }
            catch {
                print "[pgbouncer] KILL $b_db error [$_]";
            };
        }
    }

    #suppress 'WARNING:  PID 31811 is not a PostgreSQL server process'
    {
        local $SIG{__WARN__} = sub { warn @_ if $_[0] !~ /is not a PostgreSQL server process/; };
        $dbh->do(
            'select pid, pg_terminate_backend(pid) terminated
           from pg_stat_get_activity(NULL::integer) s(datid, pid)
          where pid<>pg_backend_pid()'
        );
    }
    $dbh->do('drop database if exists ' . $self->_db_name);
    $dbh->do('create database ' . $self->_db_name);
    $dbh->disconnect();

    my $m = DBIx::Migration->new({
        'dsn'      => $self->dsn,
        'dir'      => $self->_db_migrations_dir,
        'username' => 'postgres',
        'password' => $self->_connection_parameters->{'password'},
    });
    $m->migrate();

    # apply DB functions
    $m->psql(sort glob $self->_db_migrations_dir . '/functions/*.sql')
        if -d $self->_db_migrations_dir . '/functions';

    # migrate for collectordb schema
    if ($self->_db_migrations_dir =~ /bom-postgres-clientdb/) {
        $m = DBIx::Migration->new({
            dsn                 => $self->dsn,
            dir                 => '/home/git/regentmarkets/bom-postgres-collectordb/config/sql/',
            tablename_extension => 'collector',
            username            => 'postgres',
            password            => $self->_connection_parameters->{'password'},
        });

        $m->migrate();

        # apply DB functions
        $m->psql(sort glob '/home/git/regentmarkets/bom-postgres-collectordb/config/sql/functions/*.sql')
            if -d '/home/git/regentmarkets/bom-postgres-collectordb/config/sql/functions';
    }
    if (-f $self->_db_migrations_dir . '/unit_test_dml.sql') {
        $m->psql({
                before => "SET session_replication_role TO 'replica';\n",
                after  => ";\nSET session_replication_role TO 'origin';\n"
            },
            $self->_db_migrations_dir . '/unit_test_dml.sql'
        );
    }
    # TODO the file devbox_server_user_mapping.sql was removed because it seems be useless. Will recover it back if necessary later.
    if ((-f $self->_db_migrations_dir . '/devbox_foreign_servers_for_testdb.sql') && $self->_db_name =~ m/_test/) {
        $m->psql({
                before => "SET session_replication_role TO 'replica';\n",
                after  => ";\nSET session_replication_role TO 'origin';\n"
            },
            $self->_db_migrations_dir . '/devbox_foreign_servers_for_testdb.sql'
        );
    }

    foreach (@bouncer_dbs) {
        $b_db = $_;

        try {
            $pooler->do('ENABLE "' . $b_db . '"');
        }
        catch {
            print "[pgbouncer] ENABLE $b_db error [$_]";
        };

        try {
            $pooler->do('RESUME "' . $b_db . '"');
        }
        catch {
            print "[pgbouncer] RESUME $b_db error [$_]";
        };
    }

    return 1;
}

sub _migrate_file {
    my $self = shift;
    my $file = shift;

    my $dbh = $self->db_handler;
    my @sql = read_file($file);

    # STUPID way but just to prevent from running it in transaction way
    LINE:
    foreach my $line (@sql) {
        next LINE if $line =~ /^(?:--|$)/;
        $dbh->do($line);
    }

    $dbh->disconnect();
    return 1;
}

sub _update_sequence_of {
    my $self    = shift;
    my $arg_ref = shift;

    my $table    = $arg_ref->{'table'};
    my $sequence = $arg_ref->{'sequence'};

    my $dbh = $self->db_handler;

    my $statement;
    my $last_value;
    my $query_result;
    my $current_sequence_value = 0;

    $statement = qq{
        SELECT MAX(id) FROM $table;
    };
    $query_result = $dbh->selectrow_hashref($statement);
    $last_value   = $query_result->{'max'};

    while ($current_sequence_value <= $last_value) {
        $statement = qq{
            SELECT nextval('sequences.$sequence'::regclass);
        };
        $query_result = $dbh->selectrow_hashref($statement);

        $current_sequence_value = $query_result->{'nextval'};
    }

    $dbh->disconnect;

    return $current_sequence_value;
}

sub _restore_snapshot {
    my $self = shift;
    return 0 if !-f $self->snapshot;

    my $connection_settings = $self->_connection_parameters;
    system(   "PGPASSWORD="
            . $connection_settings->{password} . " "
            . $self->pg_path
            . "/pg_restore"
            . " -Fc -U postgres -h localhost -p $connection_settings->{port} -cd $connection_settings->{database}" . " -1 "
            . $self->snapshot);
    return 1;
}

sub _create_snapshot {
    my $self = shift;
    mkdir SNAPSHOT_DIR if !-d SNAPSHOT_DIR;

    my $connection_settings = $self->_connection_parameters;
    system(   "PGPASSWORD="
            . $connection_settings->{password} . " "
            . $self->pg_path
            . "/pg_dump"
            . " -Fc -U postgres -h localhost -p $connection_settings->{port} $connection_settings->{database}" . " -f "
            . $self->snapshot);
    return;
}

sub BUILD {
    my $self = shift;

    Carp::croak "Test DB trying to run to non development box"
        unless (BOM::Test::env() eq 'development');
    $ENV{TEST_DATABASE} = 1;    ## no critic (RequireLocalizedPunctuationVars)
    return;
}

sub snapshot { return SNAPSHOT_DIR . "/" . shift->_db_name . ".snapshot" }

sub pg_path { return PG_DIR . "/" . shift->server_version . "/bin/" }

sub server_version {
    my $self = shift;

    my $connection_settings = $self->_connection_parameters;
    my $ver_query =
          "PGPASSWORD="
        . $connection_settings->{password} . " "
        . PSQL
        . " -U postgres -h localhost -p "
        . $connection_settings->{port}
        . " -c 'SELECT version();'";

    my $ver = qx/$ver_query/;

    $ver =~ /PostgreSQL (\d\.\d)/;

    die "Cannot find the server version for " . $self->_db_name if not $1;

    return $1;
}

1;
