#!/usr/bin/perl

# reindex everything w/o locking

use 5.010001;
use strict;
use warnings;

use Pg::Reindex qw(prepare rebuild);

$| = 1;    ## no critic

sub lg {
    return print localtime() . ": ", @_;
}

my ($opt_help,       $opt_dbname, $opt_server,
    $opt_user,       $opt_pwd,    $opt_port,
    @opt_namespaces, @opt_tables, @opt_indexes,
    $opt_validate,   $opt_dryrun, $opt_throttle_on,
    $opt_throttle_off
);
(   $opt_user, $opt_port, $opt_server, $opt_validate, $opt_throttle_on,
    $opt_throttle_off
) = (qw/postgres 5432 localhost 1 10000000 100000/);

GetOptions(
    'help'              => \$opt_help,
    'database|dbname=s' => \$opt_dbname,
    'server=s'          => \$opt_server,
    'user=s'            => \$opt_user,
    'password=s'        => \$opt_pwd,
    'port=s'            => \$opt_port,
    'table=s'           => \@opt_tables,
    'namespace=s'       => \@opt_namespaces,
    'index=s'           => \@opt_indexes,
    'validate!'         => \$opt_validate,
    'dryrun!'           => \$opt_dryrun,
    'high-txn-lag=i'    => \$opt_throttle_on,
    'low-txn-lag=i'     => \$opt_throttle_off,
    )
    || pod2usage(
    -exitval => 1,
    -verbose => 2
    );

my $action = $ARGV[0];
if ($action) {
    if ( $action =~ /^p(?:r(?:e(?:p(?:a(?:re?)?)?)?)?)?$/i ) {
        $action = 'prepare';
    } elsif ( $action =~ /^c(?:o(?:n(?:t(?:i(?:n(?:ue?)?)?)?)?)?)?$/i ) {
        $action = 'continue';
    } else {
        pod2usage(
            -exitval => 1,
            -verbose => 2
        );
    }
}

pod2usage(
    -exitval => 0,
    -verbose => 2
) if $opt_help;

{
    my $fh;
    if ( !defined $opt_pwd ) {

        # noop
    } elsif ( $opt_pwd =~ /^\d+$/ ) {
        open $fh, '<&=' . $opt_pwd    ## no critic
            or die "Cannot open file descriptor $opt_pwd: $!\n";
        $opt_pwd = readline $fh;
        chomp $opt_pwd;
    } else {
        open $fh, '<', $opt_pwd or die "Cannot open $opt_pwd: $!\n";
        $opt_pwd = readline $fh;
        chomp $opt_pwd;
    }
    close $fh;
}

my $dbh = DBI->connect(
    "dbi:Pg:database=$opt_dbname;host=$opt_server;port=$opt_port;sslmode=prefer",
    $opt_user,
    $opt_pwd,
    {   pg_server_prepare => 0,
        PrintError        => 0,
        RaiseError        => 1,
    }
);

prepare( $dbh, \@opt_namespaces, \@opt_tables, \@opt_indexes )
    unless defined $action and $action eq 'continue';

rebuild(
    $dbh,
    {   ThrottleOn  => $opt_throttle_on,
        ThrottleOff => $opt_throttle_off,
        Validate    => $opt_validate
    },
    $opt_dryrun
) if !defined $action or $action eq 'continue';

$dbh->disconnect;

exit 0;

__END__

=encoding utf8

=head1 NAME

reindex_db.pl - rebuild indexes concurrently

=head1 SYNOPSIS

 reindex_db.pl [--help] \
               [--server=localhost] \
               [--port=5432] \
               [--user=postgres] \
               [--password=PASSWORD] \
               [--table=TABLE] ... \
               [--namespace=NAMESPACE] ... \
               [--index=INDEX] ... \
               [--[no]validate] \
               [--high_txn_lag=BYTES] \
               [--log_txn_lag=BYTES] \
               [--[no]dryrun] \
               [prepare|continue]

=head1 DESCRIPTION

For better performance, it's indicated to rebuild indexes on a regular basis.
Postgres has the C<REINDEX> command. However, building the indexes this way
requires an exclusive lock on the table. On the other hand, Postgres also has
C<CREATE INDEX CONCURRENTLY> which avoids this lock.

This script builds new indexes using C<CREATE INDEX CONCURRENTLY>. Then it
starts a transaction for each index in which it drops the old index and
renames the new one.

It handles normal indexes and C<PRIMARY KEY>, C<FOREIGN KEY> and C<UNIQUE>
constraints.

For it's own housekeeping, the script creates a new schema named C<reindex>
with 2 tables, C<worklist> and C<log>. C<Worklist> is created as C<UNLOGGED>
table. In a first step called C<prepare> the script creates its worklist.
There it notes all indexes that need to be rebuilt. Then in a second step
called C<continue> it actually builds the indexes. Both steps can be executed
separately by specifying the parameters C<prepare> or C<continue>. Also, if
script is somehow interrupted you can fix the reason and then call it again
to C<continue>.

=head2 Streaming replication and throttling

Before creating the next index, the streaming replication lag is checked to
be below a certain limit. If so, nothing special happens and the index is
built.

Otherwise, the program waits for the replicas to catch up. When the lag
drops under a second limit, the program does not immediately continue.
Instead it waits for another 30 seconds and checks the lag every second
within that period. Only if the lag stays below the limit for the whole
time, execution is continued. This grace period is to deal with the fact
that a wal sender process may suddenly disappear and reappear after a
few seconds. Without the grace period the program may encounter a false
drop below the limit and hence continue. For large indexes this adds a
lot of lag.

=head1 OPTIONS

Options can be abbreviated.

=over 4

=item --server

Hostname / IP address or directory path to use to connect to the Postgres
server. If you want to use a local UNIX domain socket, specify the socket
directory path.

Default: localhost

=item --port

The port to connect to.

Default: 5432

=item --user

The user.

Default: postgres

=item --password

a file name or open file descriptor where to read the password from.
If the parameter value consists of only digits, it's evaluated as file
descriptor.

There is no default.

A convenient way to specify the password on the BASH command line is

 reindex.pl --password=3 3<<<my_secret

That way the password appears in F<.bash_history>. But that file is
usually only readable to the owner.

=item --table

Reindex only indexes that belong to the specified table.

This option can be given multiple times.

If C<--table>, C<--namespace> and C<--index> are given simultaneously,
only indexes satisfying all conditions are considered.

=item --namespace

Without this option only namespaces are considered that are not in
beginning with C<pg_>. Also C<information_schema> or C<sequences>
namespaces are omitted.

If C<--table>, C<--namespace> and C<--index> are given simultaneously,
only indexes satisfying all conditions are considered.

=item --index

If C<--table>, C<--namespace> and C<--index> are given simultaneously,
only indexes satisfying all conditions are considered.

=item --[no]validate

validate C<FOREIGN KEY> constraints or leave them C<NOT VALID>. Default
it to validate.

=item --[no]dryrun

don't modify the database but print the essential SQL statements.

=item --high-txn-lag

the upper limit streaming replicas may lag behind in bytes.

Default is 10,000,000.

=item --low-txn-lag

the lower limit in bytes when execution may be continued after it has been
interrupted due to exceeding C<high_txn_lag>.

Default is 100,000

=item --help

print this help

=back

=head1 AUTHOR

Torsten Förtsch E<lt>torsten@binary.comE<gt>
