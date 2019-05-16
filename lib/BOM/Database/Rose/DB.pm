package BOM::Database::Rose::DB;

use strict;
use warnings;
use Carp;

use Mojo::Exception;
use DBIx::Connector::Pg;
use parent 'Rose::DB';

# If you are seeing connections being attempted to this Rose::DB
# object, it's because you are failing to set ->db() for your
# Rose::DB::Object-derived class before using it. Because of the
# explicit connection roles (read, write, master_write, etc.) that
# we use in our system, as well as the complexity of having multiple
# landing companies, it is senseless to define a default set of
# connection parameters. This placeholder definition serves only
# as a guidepost to bring developers back to this comment so that
# they can see the error of their ways. Oh, and because Rose::DB::*
# requires it as well :-)
__PACKAGE__->register_db(
    domain   => 'dummy',
    type     => 'dummy',
    driver   => 'Pg',
    database => $ENV{BOMDB_DBS} || 'dummy',
    host     => $ENV{BOMDB_HOST} || 'localhost',
    port     => $ENV{BOMDB_PORT} || 5432,
    username => $ENV{BOMDB_USER} || 'dummy',
    #password         => 'dummy',
    server_time_zone => 'UTC',
    print_error      => 0,
);

__PACKAGE__->default_domain('dummy');
__PACKAGE__->default_type('dummy');

__PACKAGE__->default_connect_options(
    pg_enable_utf8    => 1,
    pg_server_prepare => 0,
    HandleError       => sub { return _handle_errors(@_) },
    PrintError        => 0,
    PrintWarn         => 0,
);

__PACKAGE__->db_cache_class('BOM::Database::Rose::DB::Cache');

# Moving into its own sub here so legacy code can temporarily re-use it.
# Error severity is as follows:
#
# warn:  Someone should probably take a look at this
# error: This may cause the system to go down.  Start paging people....

sub _handle_errors {
    my $error_message = shift;
    my $sth           = shift;
    my $dbh           = eval { $sth->isa('DBI::st') } ? $sth->{Database} : $sth;
    my $state         = $dbh->state;
    my $severity      = _get_severity($state);
    my $err           = $dbh->err || "[none]";
    $error_message ||= '[None Passed]';
    $state         ||= "[none]";

    ## For our self-generated errors, we do not need the full context in the error message
    if ($state =~ /^BI...$/) {
        (my $clean_message = $dbh->errstr) =~ s/\nCONTEXT:.+//s;
        die [$state, $clean_message];
    }

    warn "DB Error Severity: $severity, $error_message. SQLSTATE=$state. Error=$err";

    die Mojo::Exception->new($dbh->errstr || $error_message);
}

# THis is also used by legacy code currently, but as the legacy code goes away,
# this can become fully private
#
# It accepts a SQL State, and then returns either 'warn' or 'error'
#
# This is so we can page people on more severe errors, but warn of less severe
# errors.

sub _get_severity {
    my $state = shift;

    my %error_states = (
        '09' => 'Triggered Action Exception',
        '0B' => 'Invalid Transaction Initiation',
        '0F' => 'Locator Exception',
        '0L' => 'Invalid Grantor',
        '0P' => 'Invalid Role Specification',
        '20' => 'Case Not Found',
        '21' => 'Cardinality Violation',
        '24' => 'Invalid Cursor State',
        '25' => 'Invalid Transaction State',
        '26' => 'Invalid SQL Statement Name',
        '27' => 'Triggered Data Change Violation',
        '28' => 'Invalid Authorization Specification',
        '2B' => 'Dependent Privilege Descriptors Still Exist',
        '2D' => 'Invalid Transaction Termination',
        '2F' => 'SQL Routine Exception',
        '34' => 'Invalid Cursor Name',
        '38' => 'External Routine Exception',
        '39' => 'External Routine Invocation Exception',
        '3B' => 'Savepoint Exception',
        '3D' => 'Invalid Catalog Name',
        '42' => 'Invalid Catalog Name',
        '53' => 'Insufficient Resources',
        '55' => 'Object Not In Prerequisite State',
        '58' => 'External System Error',
        'F0' => 'Configuration File Error',
        'P0' => 'PL/PGSQL Error',
        'XX' => 'Internal Error'
    );
    if ($state eq '57P02' or $state eq '42P01') {
        return 'error';
    } else {
        my $state_class = $state;
        $state_class =~ s/^(.{2}).*/$1/;
        return 'error' if exists $error_states{$state_class};
    }
    return 'warn';
}

sub dbic {
    my $self = shift;
    $self->init_dbh unless $self->{dbic};
    return $self->{dbic};
}

sub dbi_connect {
    my ($self, @params) = @_;

    # Add extra parameters to the DSN. I tried to do that the right way.
    # But it means to create at least our own implementations of
    # Rose::DB::Registry and Rose::DB::Registry::Entry and to overwrite
    # Rose::DB::Registry::add_entries() which is a lengthy function.
    # To do it here seems a bit hacky but I think it's okay.
    $params[0] = join(
        ';',
        $params[0],
        qw/ keepalives=1
            keepalives_idle=180
            keepalives_interval=5
            keepalives_count=10 /,
    );

    if (not exists $self->{dbic}) {
        $self->{dbic} = DBIx::Connector::Pg->new(@params);
        # fixup mode is a safe and quick mode. That's why we switch from DBI  to  DBIx::Connector.
        # So we set it as default mode
        # But if the sub block will affect the outer environment, please use 'ping' mode instead.
        # Please refer to the document of DBIx::Connector .
        $self->{dbic}->mode('fixup');
    }
    my $dbh = $self->{dbic}->dbh;

    return $dbh;
}

1;
