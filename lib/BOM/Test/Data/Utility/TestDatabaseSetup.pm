package BOM::Test::Data::Utility::TestDatabaseSetup;

use Moose::Role;
use Carp;
use DBI;
use Path::Tiny;
use Syntax::Keyword::Try;
use DBIx::Migration;
use BOM::Test;
use Test::More;
use List::Util qw( max );
use File::stat;
use BOM::Config;

requires '_db_name', '_post_import_operations', '_build__connection_parameters', '_db_migrations_dir';

use constant DB_DIR_PREFIX    => '/home/git/regentmarkets/bom-postgres-';
use constant COLLECTOR_DB_DIR => DB_DIR_PREFIX . 'collectordb/config/sql/';

BEGIN {
    die "wrong env. Can't run test" if (BOM::Test::env !~ /^(qa\d+|development)$/);
}

sub prepare_unit_test_database {
    my $self = shift;

    try {
        $self->_migrate_changesets;
        $self->_post_import_operations;
    }
    catch {
        Carp::croak '[' . $0 . '] preparing unit test database failed. ' . $@;
    }
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
                $self->_do_quoted($pooler, 'DISABLE %s', $b_db);
                #$self->_do_quoted($pooler, 'PAUSE  %s', $b_db);
            }
            catch {
                print "[pgbouncer] DISABLE $b_db error [$@]";
            }

            try {
                $self->_do_quoted($pooler, 'KILL %s', $b_db);
            }
            catch {
                print "[pgbouncer] KILL $b_db error [$@]";
            }
        }
    }

    $self->_create_dbs unless $self->_restore_dbs_from_template;

    for my $b_db (@bouncer_dbs) {
        try {
            $self->_do_quoted($pooler, 'ENABLE %s', $b_db);
        }
        catch {
            print "[pgbouncer] ENABLE $b_db error [$@]";
        }

        try {
            $self->_do_quoted($pooler, 'RESUME %s', $b_db);
        }
        catch {
            print "[pgbouncer] RESUME $b_db error [$@]";
        }
    }

    return 1;
}

sub _create_dbs {
    my $self = shift;
    my $dbh  = $self->_kill_all_pg_connections;

    local $SIG{__WARN__} = sub { warn @_ if $_[0] !~ /database ".*_test" does not exist, skipping/; };
    $self->_do_quoted($dbh, 'DROP DATABASE IF EXISTS %s', $self->_db_name);
    $self->_do_quoted($dbh, 'CREATE DATABASE %s',         $self->_db_name);
    $dbh->disconnect;

    my $m = DBIx::Migration->new({
        'dsn'      => $self->dsn,
        'dir'      => $self->_db_migrations_dir,
        'username' => 'postgres',
        'password' => $self->_connection_parameters->{'password'},
    });
    $m->migrate();

    # apply DB functions
    $m->psql(sort glob $self->_db_migrations_dir =~ s!/*$!/functions/*.sql!r) if (-d $self->_db_migrations_dir . 'functions');

    if (-f $self->_db_migrations_dir . '/unit_test_dml.sql') {
        $m->psql({
                before => "SET session_replication_role TO 'replica';\n",
                after  => ";\nSET session_replication_role TO 'origin';\n"
            },
            $self->_db_migrations_dir . '/unit_test_dml.sql'
        );
    }

    # Because we have different database setups for devbox and CI, foreign servers need to configured differently
    # depending on the environment.
    my $foreign_server_setup_sql = $self->_db_migrations_dir . '/devbox_foreign_servers_for_testdb.sql';
    if (BOM::Config::on_development()) {    # Circle CI test
        $foreign_server_setup_sql = $self->_db_migrations_dir . '/circleci_foreign_servers_for_testdb.sql';
    }

    if (-f $foreign_server_setup_sql) {
        $m->psql({
                before => "SET session_replication_role TO 'replica';\n",
                after  => ";\nSET session_replication_role TO 'origin';\n"
            },
            $foreign_server_setup_sql
        );
    }

    return $self->_create_template;
}

sub _migrate_file {
    my $self = shift;
    my $file = shift;

    my $dbh = $self->db_handler;
    my @sql = path($file)->lines_utf8;

    # STUPID way but just to prevent from running it in transaction way
    LINE:
    foreach my $line (@sql) {
        next LINE if $line =~ /^(?:--|$)/;
        $dbh->do($line);
    }

    $dbh->disconnect;
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

sub _restore_dbs_from_template {
    my $self = shift;
    return 0 unless $self->_is_template_usable;
    my $is_successful = 0;
    try {
        my $dbh = $self->_kill_all_pg_connections;
        my ($db_name, $tmpl_name) = ($self->_db_name, $self->_template_name);
        $self->_do_quoted($dbh, 'DROP DATABASE IF EXISTS %s', $db_name);
        $self->_do_quoted($dbh, 'CREATE DATABASE %s WITH TEMPLATE %s', $db_name, $tmpl_name);
        $dbh->disconnect;
        $is_successful = 1;
    }
    catch {
        note 'Falling back to restoring schemas, because restoring the db template failed for ' . $self->_db_name . ' with error: ' . $@;
    }

    return $is_successful;
}

sub _create_template {
    my $self = shift;

    try {
        my $dbh = $self->_kill_all_pg_connections;
        # suppress 'NOTICE:  database ".*template" does not exist, skipping'
        local $SIG{__WARN__} = sub { warn @_ if $_[0] !~ /database ".*_template" does not exist, skipping/; };

        my ($db_name, $tmpl_name) = ($self->_db_name, $self->_template_name);

        $self->_do_quoted($dbh, 'DROP DATABASE IF EXISTS %s',          $tmpl_name);
        $self->_do_quoted($dbh, 'ALTER DATABASE %s RENAME TO %s',      $db_name, $tmpl_name);
        $self->_do_quoted($dbh, 'CREATE DATABASE %s WITH TEMPLATE %s', $db_name, $tmpl_name);
        $dbh->disconnect;
    }
    catch {
        note 'Creating the db template failed for ' . $self->_db_name . ' with error: ' . $@;
    }
    return;
}

sub _kill_all_pg_connections {
    my $self = shift;

    my $dbh = $self->_postgres_dbh;

    #suppress 'WARNING:  PID 31811 is not a PostgreSQL server process'
    {
        local $SIG{__WARN__} = sub { warn @_ if $_[0] !~ /is not a PostgreSQL server process/; };

        # kill connections to db except itself and pglogical
        my $db_name = $self->_db_name;
        $dbh->do(
            "SELECT pg_terminate_backend(pid)
                    FROM pg_stat_activity
                   WHERE pid <> pg_backend_pid()
                     AND application_name NOT LIKE '%pglogical%'
                     AND datname = '$db_name'"
        );
    }

    return $dbh;
}

sub _is_template_usable {
    my $self = shift;

    my @timestamps = map { $self->_pg_code_timestamp($_) } $self->_get_db_dir;

    return $self->_get_template_age > max @timestamps;
}

sub _pg_code_timestamp {
    my ($self, $pg_dir) = @_;

    my $error_occured = system("cd $pg_dir && make -s timestamp");

    # If we fail to make the timestamp, return inf to make template unusable
    return $error_occured ? 'inf' : stat("$pg_dir/timestamp")->mtime;
}

sub _get_template_age {
    my $self = shift;

    my $dbh = $self->_postgres_dbh;

    # Get the template age in epoch, 0 if there is no template
    my ($template_date) = $dbh->selectrow_array(<<'SQL', undef, $self->_template_name);
SELECT coalesce(max(
           extract(epoch from (pg_stat_file('base/'|| oid ||'/PG_VERSION')).modification)
       ), 0)
  FROM pg_database
 WHERE datname = ?
SQL

    $dbh->disconnect;

    return $template_date;
}

sub _get_db_dir {
    my $self = shift;

    my $migration_dir = $self->_db_migrations_dir;

    my @db_dirs = ($migration_dir);
    push @db_dirs, COLLECTOR_DB_DIR if $migration_dir =~ /bom-postgres-clientdb/;

    my $PREFIX = DB_DIR_PREFIX;

    # Return the absolute path to repo folders e.g. /home/.../bom-postgres-clientdb/
    return map { s{$PREFIX[^/]*\K.*}{}gr . '/' } @db_dirs;
}

sub _template_name { return shift->_db_name . '_template' }

sub _do_quoted {
    my ($self, $dbh, $query, @args) = @_;

    return $dbh->do(sprintf $query, map { $dbh->quote_identifier($_) } @args);
}

sub _postgres_dbh {
    my $self = shift;

    my $dbh = $self->db_handler('postgres');

    # die if any operation fails
    $dbh->{RaiseError} = 1;
    $dbh->{PrintError} = 0;

    return $dbh;
}

sub BUILD {
    my $self = shift;

    Carp::croak "Test DB trying to run to non development box"
        unless (BOM::Test::env() eq 'development');
    $ENV{TEST_DATABASE} = 1;    ## no critic (RequireLocalizedPunctuationVars)
    return;
}

1;
