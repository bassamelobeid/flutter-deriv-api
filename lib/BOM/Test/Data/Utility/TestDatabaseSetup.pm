package BOM::Test::Data::Utility::TestDatabaseSetup;

use Moose::Role;
use Carp;
use DBI;
use File::Slurp;
use Try::Tiny;
use DBIx::Migration;
use BOM::Platform::Runtime;
use File::Temp qw/tempfile/;

requires '_db_name', '_post_import_operations', '_build__connection_parameters', '_db_migrations_dir';

sub _collectordb_migrations_dir {
    my $self = shift;
    if ($self->_db_migrations_dir eq 'rmgdb') {
        return 'collectordb';
    }
    return;
}

sub prepare_unit_test_database {
    my $self = shift;

    try {
        $self->_migrate_changesets;
        $self->_alter_user_mapping if ($self->_db_migrations_dir eq 'rmgdb');
        $self->_post_import_operations;
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
    return 'dbi:Pg:dbname=' . $db . ';host=' . $connection_settings->{'host'} . ';port=' . $connection_settings->{'port'};
}

sub db_handler {
    my $self = shift;
    my $db   = shift;
    my $dbh  = DBI->connect($self->dsn($db), 'postgres', $self->_connection_parameters->{'password'})
        or croak $DBI::errstr;
    return $dbh;
}

has 'changesets_location' => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_changesets_location {
    my $self = shift;
    return '/home/git/regentmarkets/bom-postgres/config/sql/' . $self->_db_migrations_dir . '/';
}

has 'collectordb_changesets_location' => (
    is         => 'rw',
    isa        => 'Maybe[Str]',
    lazy_build => 1,
);

sub _build_collectordb_changesets_location {
    my $self = shift;

    if ($self->_db_migrations_dir eq 'rmgdb') {
        return '/home/git/regentmarkets/bom-postgres/config/sql/collectordb/';
    }
    return;
}

sub _migrate_changesets {
    my $self = shift;

    my $dbh = $self->db_handler('postgres');
    $dbh->{RaiseError} = 1;    # die if we cannot perform any of the operations below
    $dbh->{PrintError} = 0;

    # first teminate all other connections
    $dbh->do(
        'select pid, pg_terminate_backend(pid) terminated
           from pg_stat_get_activity(NULL::integer) s(datid, pid)
          where pid<>pg_backend_pid()'
    );
    $dbh->do('drop database if exists ' . $self->_db_name);
    $dbh->do('create database ' . $self->_db_name);
    $dbh->disconnect();

    my $m = DBIx::Migration->new({
        'dsn'      => $self->dsn,
        'dir'      => $self->changesets_location,
        'username' => 'postgres',
        'password' => $self->_connection_parameters->{'password'},
    });
    $m->migrate();

    # apply DB functions
    $m->psql(sort glob $self->changesets_location . '/functions/*.sql')
        if -d $self->changesets_location . '/functions';

    # migrate for collectordb schema
    if ($self->_db_migrations_dir eq 'rmgdb') {
        $m = DBIx::Migration->new({
            dsn                 => $self->dsn,
            dir                 => $self->collectordb_changesets_location,
            tablename_extension => 'collector',
            username            => 'postgres',
            password            => $self->_connection_parameters->{'password'},
        });

        $m->migrate();

        # apply DB functions
        $m->psql(sort glob $self->collectordb_changesets_location . '/functions/*.sql')
            if -d $self->collectordb_changesets_location . '/functions';
    }

    if (-f $self->changesets_location . '/unit_test_dml.sql') {
        my ($fh, $fn) = tempfile undef, UNLINK => 1;
        $fh->autoflush(1);

        my ($dbname, $dbuser, $dbhost, $dbport, $dbpass) = @{$m->{_dbh}}{qw/pg_db pg_user pg_host pg_port pg_pass/};

        local @ENV{qw/PGPASSFILE PGHOST PGPORT PGDATABASE PGUSER/} = ($fn, $dbhost, $dbport, $dbname, $dbuser);
        print $fh "$dbhost:$dbport:$dbname:$dbuser:$dbpass\n";

        local $SIG{PIPE} = 'IGNORE';

        my $pid = open my $psql_in, '|-';    ## no critic
        die "Cannot start psql: $!\n" unless defined $pid;
        unless ($pid) {
            open STDOUT, '>', '/dev/null' or warn "Cannot open /dev/null: $!\n";
            exec qw/psql -q -v ON_ERROR_STOP=1/;
            warn "Cannot exec psql: $!\n";
            CORE::exit 254;
        }

        print $psql_in "SET client_min_messages TO warning;\n"          or die "Cannot write to psql: $!\n";
        print $psql_in "SET session_replication_role TO 'replica';\n"   or die "Cannot write to psql: $!\n";
        my $name = $self->changesets_location . '/unit_test_dml.sql';
        print $psql_in "\\i $name\n"                                    or die "Cannot write to psql: $!\n";
        print $psql_in ";\nSET session_replication_role TO 'origin';\n" or die "Cannot write to psql: $!\n";
        close $psql_in and return;

        $! and die "Cannot write to psql: $!\n";

        my $sig = $? & 0x7f;    # ignore the highest bit which indicates a coredump
        die "psql killed by signal $sig" if $sig;

        my $rc = $? >> 8;
        die "psql returns 1 (out of memory, file not found or similar)\n" if $rc == 4;
        die "psql returns 2 (connection problem)\n"                       if $rc == 2;
        die "psql returns 3 (script error)\n"                             if $rc == 3;
        die "cannot exec psql\n"                                          if $rc == 254;
        die "psql returns unexpected code $rc\n";
    }

    return 1;
}

sub _import_sample_data {
    my $self = shift;

    my $filename = $self->changesets_location . '/unit_test_dml.sql';
    if (-e $filename) {
        $self->_migrate_file($filename);
    }
    return 1;
}

sub _alter_user_mapping {
    my $self = shift;
    return if ($self->_db_migrations_dir ne 'rmgdb');

    $self->_migrate_file($self->changesets_location . '/devbox_server_user_mapping.sql');
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

sub BUILD {
    my $self = shift;

    Carp::croak "Test DB trying to run to non development box"
        unless (File::Slurp::read_file('/etc/rmg/environment') eq 'development');

    return;
}

1;
