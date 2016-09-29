package BOM::Database::Rose::DB;

use strict;
use warnings;
use Carp;

use BOM::Database;

use Mojo::Exception;

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
    my $err           = $dbh->err   || "[none]";
    $error_message    ||= '[None Passed]';
    $state            ||= "[none]";

    # Exceptions are really ugly. They obfuscate the control flow
    # just like "goto" or even worse.
    # These exceptions are supposed to be caught
    die [$state, $dbh->errstr] if $state =~ /^BI...$/;

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

sub dbi_connect {
    my ($class, @params) = @_;

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

    return DBI->connect(@params) || croak $DBI::errstr;
}

sub disconnect {
    my $self = shift;
    if(my $category = $self->_category_from_domain) {
        BOM::Database::release_dbh($category => $self->{dbh}) if $self->{dbh};
    } else {
        warn "No database category, cannot unregister";
    }
    $self->SUPER::disconnect(@_);
}

sub new_or_cached {
    my $class = shift;
    unshift @_, 'type' if @_ == 1;
    my %args = @_;
    my $db = $class->SUPER::new_or_cached(%args);
    if(my $category = $class->_category_from_domain($args{domain})) {
        if(my $dbh = $db->{dbh}) {
            BOM::Database::register_dbh($category => $dbh) unless BOM::Database::dbh_is_registered($category => $dbh);
        } else {
            warn "No database handle assigned for category [$category]";
        }
    } else {
        # Should never happen, since we have a default
        warn "No database category, cannot register";
    }
    return $db;
}

=head2 _category_from_domain

Takes an optional domain and returns a suitable category string for use with L<BOM::Database> registration.

Will apply the default domain from the class if nothing else is found.

May return undef if it was not possible to determine a suitable category - but since we have a default, this should
not happen.

=cut

sub _category_from_domain {
    # Note that this can be called as an instance method or a class method, guard all attribute
    # lookups with a ref($self) check
    my ($self, $domain) = @_;

    my $category = $domain;
    $category //= $self->{domain} if ref $self;
    $category //= $self->default_domain or return undef;

    # Remove trailing 'db', so userdb => user, authdb => auth etc.
    $category =~ s/db$// unless $category eq 'db';
    return $category;
}

1;
