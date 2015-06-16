#!/usr/bin/perl

# reindex everything w/o locking

use 5.010001;
use strict;
use warnings;

use DBI;
use DBD::Pg qw/:async/;
use AnyEvent;
use POSIX qw/SIGTERM SIGINT SIG_BLOCK SIG_UNBLOCK/;
use Getopt::Long;
use Pod::Usage;
use Time::HiRes ();

$| = 1;    ## no critic

sub lg {
    return print localtime() . ": ", @_;
}

my (
    $opt_help,   $opt_dbname,  $opt_server,   $opt_user,   $opt_pwd,         $opt_port, @opt_namespaces,
    @opt_tables, @opt_indexes, $opt_validate, $opt_dryrun, $opt_throttle_on, $opt_throttle_off
);
($opt_user, $opt_port, $opt_server, $opt_validate, $opt_throttle_on, $opt_throttle_off) = (qw/postgres 5432 localhost 1 10000000 100000/);

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
    if ($action =~ /^p(?:r(?:e(?:p(?:a(?:re?)?)?)?)?)?$/i) {
        $action = 'prepare';
    } elsif ($action =~ /^c(?:o(?:n(?:t(?:i(?:n(?:ue?)?)?)?)?)?)?$/i) {
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
    if (!defined $opt_pwd) {
        # noop
    } elsif ($opt_pwd =~ /^\d+$/) {
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
    {
        pg_server_prepare => 0,
        PrintError        => 0,
        RaiseError        => 1,
    });

sub query {
    my ($descr, @param) = @_;
    my $sql = pop @param;

    # warn $sql;

    my $tm = Time::HiRes::time;

    my $stmt = ref $sql ? $sql : $dbh->prepare($sql, {pg_async => PG_ASYNC});

    my $done   = AE::cv;
    my $cancel = sub {
        $dbh->pg_cancel if $dbh->{pg_async_status} == 1;
        $done->send;
    };
    my $pg_w = AE::io $dbh->{pg_socket}, 0, sub {
        $dbh->pg_ready and $done->send;
    };

    my $sigblock = POSIX::SigSet->new(SIGTERM, SIGINT);
    POSIX::sigprocmask SIG_BLOCK, $sigblock;
    my @sig_w = map { AE::signal $_, $cancel } qw/TERM INT/;
    $stmt->execute(@param);
    POSIX::sigprocmask SIG_UNBLOCK, $sigblock;

    $done->wait;

    die "query cancelled\n" unless $dbh->{pg_async_status} == 1;

    my $rc = $dbh->pg_result;
    my $result = $stmt->{Active} ? $stmt->fetchall_arrayref : undef;

    lg sprintf "$descr took %.3f s\n", (Time::HiRes::time- $tm) if $descr;

    return wantarray ? ($rc, $result) : $result;
}

sub wquery {    ## no critic
    goto \&query unless $opt_dryrun;

    my ($descr, @param) = @_;
    my $sql = pop @param;

    my $n = 1;
    $sql =~ s/\?/'$'.$n++/ge;
    $sql =~ s/\$(\d+)/$dbh->quote($param[$1-1])/ge;

    print "$sql;\n";

    return 1;
}

sub throttle {
    return if $opt_dryrun;
    state $q = $dbh->prepare(<<'SQL', {pg_async => PG_ASYNC});
SELECT coalesce(max(pg_xlog_location_diff(pg_current_xlog_location(), r.flush_location)), 0)
  FROM pg_stat_replication r
SQL

    my ($xlog_diff) = @{query('', $q)->[0]};

    if ($xlog_diff > $opt_throttle_on) {
        lg "streaming lag = $xlog_diff ==> pausing\n";
        LOOP: {
            do {
                select undef, undef, undef, 1;    ## no critic
                ($xlog_diff) = @{query('', $q)->[0]};
            } while ($xlog_diff > $opt_throttle_off);

            # sleep for another 30 sec and check every second the lag.
            # sometimes the wal sender process disconnects and reconnects
            # a moment later. In that case we may have fallen below the
            # throttle limit simply because we checked at the wrong time.
            for (my $i = 0; $i < 30; $i++) {
                select undef, undef, undef, 1;    ## no critic
                ($xlog_diff) = @{query('', $q)->[0]};
                redo LOOP if $xlog_diff > $opt_throttle_off;
            }
        }
        lg "streaming lag = $xlog_diff -- continuing\n";
    }
    return;
}

sub prepare {
    my $qual;
    my @param;

    query '', 'SET client_min_messages TO WARNING';

    query '', 'CREATE SCHEMA IF NOT EXISTS reindex';

    query '', <<'SQL';
CREATE TABLE IF NOT EXISTS reindex.log(
  id BIGSERIAL PRIMARY KEY,
  tstmp TIMESTAMP,
  nspname NAME,
  tblname NAME,
  idxname NAME,
  sz_before BIGINT,
  sz_after BIGINT,
  status TEXT,
  tm_taken INTERVAL
)
SQL

    query '', <<'SQL';
CREATE UNLOGGED TABLE IF NOT EXISTS reindex.worklist(
  ord SERIAL,
  idx OID,
  status TEXT
)
SQL

    return if defined $action and $action eq 'continue';

    if (@opt_namespaces) {
        $qual .= "   AND n.nspname IN (" . join(', ', ('?') x (0 + @opt_namespaces)) . ")\n";
        push @param, @opt_namespaces;
    } else {
        $qual .= <<'SQL';
   AND n.nspname !~ '^pg_'
   AND n.nspname <> 'information_schema'
   AND n.nspname <> 'reindex'
SQL
    }

    if (@opt_tables) {
        $qual .= "   AND EXISTS(SELECT 1
                FROM pg_catalog.pg_class xc
                JOIN pg_catalog.pg_index xi ON xc.oid=xi.indrelid
               WHERE xi.indexrelid=c.oid
                 AND xc.relname IN (" . join(', ', ('?') x (0 + @opt_tables)) . "))\n";
        push @param, @opt_tables;
    }

    if (@opt_indexes) {
        $qual .= "   AND c.relname IN (" . join(', ', ('?') x (0 + @opt_indexes)) . ")\n";
        push @param, @opt_indexes;
    }

    query '', 'TRUNCATE reindex.worklist';
    query '', q{SELECT pg_catalog.setval('reindex.worklist_ord_seq', 1, false)};

    query '', @param, <<'SQL'. $qual . <<'SQL';
INSERT INTO reindex.worklist(idx, status)
SELECT c.oid, 'planned'
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON c.relnamespace=n.oid
 WHERE c.relkind = 'i'
SQL
 ORDER BY n.nspname, c.relname
SQL
    return;
}

sub next_index {
    my @list = query '', <<'SQL';
WITH wl AS (
    UPDATE reindex.worklist
       SET status='in progress'
     WHERE idx=(SELECT idx
                 FROM reindex.worklist
                 WHERE status<>'done'
                 ORDER BY ord
                 LIMIT 1)
 RETURNING idx
)
SELECT c.oid, n.nspname, quote_ident(n.nspname), c.relname, quote_ident(c.relname),
       pg_catalog.pg_get_indexdef(c.oid) indexdef,
       pg_catalog.pg_relation_size(c.oid::regclass)
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON c.relnamespace=n.oid
  JOIN wl ON wl.idx=c.oid
SQL

    return @{$list[1]->[0] || []};
}

sub do_transaction {
    my ($stmt_pointer, $limit, $sub) = @_;

    LOOP: {
        eval {
            if ($opt_dryrun)
            {
                wquery '', 'BEGIN ISOLATION LEVEL REPEATABLE READ';
            } else {
                $dbh->begin_work;
                wquery '', 'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ';
            }

            $sub->();

            if ($opt_dryrun) {
                wquery '', 'COMMIT';
            } else {
                $dbh->commit;
            }
            1;
        } or do {
            my $sqlstate = $dbh->state;
            my $err      = $@;
            eval { $dbh->rollback };    ## no critic
            if ($limit--) {
                for my $state (qw/40P01 40001/) {    # deadlock detected; serialization failure
                    if ($sqlstate eq $state) {
                        $err = ">>$$stmt_pointer<<\n$err" if $stmt_pointer;
                        $err =~ s/\s+$//;
                        $err =~ s/\n/\n      /g;
                        lg "      SQL state $state ==> retry transaction\n      $err\n";
                        redo LOOP;
                    }
                }
            }
            die $err;
        };
    }
    return;
}

sub wait_for_concurrent_tx {
    return if $opt_dryrun;
    eval {
        $dbh->begin_work;

        while (!query('', 'SELECT txid_current()=txid_snapshot_xmin(txid_current_snapshot())')->[0]->[0]) {
            select undef, undef, undef, .5;    ## no critic
        }

        $dbh->rollback;
        1;
    } or do {
        my $err = $@;
        eval { $dbh->rollback };               ## no critic
        die $err;
    };
    return;
}

sub reindex {
    my ($oid, $nspname, $quoted_nspname, $idxname, $quoted_idxname, $idxdef, $size) = @_;

    throttle;                                  # wait for streaming replicas to catch up

    lg "Rebuilding Index $quoted_nspname.$quoted_idxname\n";

    my @log_id;
    @log_id = query '', $oid, <<'SQL' unless $opt_dryrun;
INSERT INTO reindex.log(tstmp, nspname, tblname, idxname, sz_before, status)
SELECT now(), n.nspname, tc.relname, ic.relname, pg_catalog.pg_relation_size(i.indexrelid::regclass), 'started'
  FROM pg_catalog.pg_index i
  JOIN pg_catalog.pg_class ic ON i.indexrelid=ic.oid
  JOIN pg_catalog.pg_class tc ON i.indrelid=tc.oid
  JOIN pg_catalog.pg_namespace n ON ic.relnamespace=n.oid
 WHERE i.indexrelid=$1
RETURNING id
SQL

    my $tmp = '__temp_reidx';
    $idxdef =~ s/^(CREATE (?:UNIQUE )?INDEX) (\S+)/$1 CONCURRENTLY $tmp/
      or die "Cannot replace index name in $idxdef\n";

    my $retry = 5;
    my (@rc, $err);
    while (--$retry > 0) {
        @rc = eval { wquery "  CREATE CONCURRENTLY", $idxdef } and last;
        $err = $@;
        eval { query "$quoted_nspname.$quoted_idxname creation failed. Dropping", qq{DROP INDEX $quoted_nspname.$tmp}; 1 }
          or warn "While dropping the index: $@";
    }

    unless ($rc[0]) {
        chomp $err;

        query '', $log_id[1]->[0]->[0], $err, <<'SQL' unless $opt_dryrun;
UPDATE reindex.log
   SET status='failed to create temp index: ' || $2,
       tm_taken=now()-tstmp
 WHERE id=$1
SQL

        die "Cannot create index: $err";
    }

    my @revalidate;
    my $current_cmd;

    eval {
        do_transaction \$current_cmd, 100, sub {
            # check if the index still exists
            @rc = query '', $oid, $nspname, $idxname, $current_cmd = <<'SQL';
SELECT 1
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
 WHERE c.oid=$1
   AND c.relkind='i'
   AND n.nspname=$2
   AND c.relname=$3
SQL

            if ($rc[1]->[0]->[0] == 1) {
                unless ($opt_dryrun) {
                    @rc = query '', $log_id[1]->[0]->[0], "$quoted_nspname.$tmp", $current_cmd = <<'SQL';
UPDATE reindex.log
   SET sz_after=pg_catalog.pg_relation_size($2::regclass)
 WHERE id=$1
RETURNING sz_after
SQL
                    lg sprintf("    size: %d ==> %d (%.2f%%)\n", $size, $rc[1]->[0]->[0], $rc[1]->[0]->[0] * 100 / $size - 100);
                }

                my @trans = ("ALTER INDEX $quoted_nspname.$tmp RENAME TO $quoted_idxname");
                @rc = query '', $oid, <<'SQL';
SELECT con.conname, quote_ident(con.conname),
       n.nspname, quote_ident(n.nspname),
       con.contype,
       pg_get_constraintdef(con.oid),
       con.conrelid::regclass::text,
       con.confrelid::regclass::text,
       con.confmatchtype,
       key.key, fkey.fkey
  FROM pg_catalog.pg_constraint con
  JOIN pg_catalog.pg_namespace n ON n.oid=con.connamespace
 CROSS JOIN LATERAL (SELECT array_agg(quote_ident(a.attname))
                       FROM unnest(con.conkey) x(k) JOIN pg_catalog.pg_attribute a
                         ON x.k=a.attnum AND a.attrelid=con.conrelid) key(key)
 CROSS JOIN LATERAL (SELECT array_agg(quote_ident(a.attname))
                       FROM unnest(con.confkey) x(k) JOIN pg_catalog.pg_attribute a
                         ON x.k=a.attnum AND a.attrelid=con.confrelid) fkey(fkey)
  JOIN (VALUES ('p'::TEXT, 1::INT),
               ('u'::TEXT, 2::INT),
               ('f'::TEXT, 3::INT)) ord(type, ord) ON ord.type=con.contype
 WHERE con.conindid=$1
   AND con.contype<>'x'        -- exclusion constraints are not yet implemented
 ORDER BY ord.ord ASC
SQL

                if (@{$rc[1]}) {
                    for my $con (@{$rc[1]}) {
                        my ($conname, $quoted_conname, $nspname, $quoted_nspname, $contype, $condef, $rel, $frel, $matchtype, $key, $fkey) = @$con;
                        if ($contype eq 'u') {
                            unshift @trans, "ALTER TABLE $rel DROP CONSTRAINT $quoted_conname";
                            push @trans, ("ALTER TABLE $rel ADD  CONSTRAINT $quoted_conname " . "UNIQUE USING INDEX $quoted_idxname");
                        } elsif ($contype eq 'p') {
                            unshift @trans, "ALTER TABLE $rel DROP CONSTRAINT $quoted_conname";
                            push @trans, ("ALTER TABLE $rel ADD  CONSTRAINT $quoted_conname " . "PRIMARY KEY USING INDEX $quoted_idxname");
                        } elsif ($contype eq 'f') {
                            unshift @trans, "ALTER TABLE $rel DROP CONSTRAINT $quoted_conname";
                            push @trans, "ALTER TABLE $rel ADD  CONSTRAINT $quoted_conname $condef NOT VALID";
                            push @revalidate, $con;    # needs to be revalidated after commit
                        } elsif ($contype eq 'x') {
                            ...;                       # exclusion constraints are not yet implemented
                        } else {
                        }
                    }
                } else {
                    unshift @trans, "DROP INDEX $quoted_nspname.$quoted_idxname";
                }

                wquery '', $current_cmd = $_ for (@trans);
            } else {
                eval { query "Index $quoted_nspname.$quoted_idxname has vanished. Dropping temporary", qq{DROP INDEX $quoted_nspname.$tmp}; 1 }
                  or warn "While dropping the index: $@";
            }
        };

        1;
    } or do {
        my $err = $@;
        chomp $err;
        $err = ">>$current_cmd<<\n$err";

        eval { query "Transaction for $quoted_nspname.$quoted_idxname failed. Dropping", qq{DROP INDEX $quoted_nspname.$tmp}; 1 }
          or warn "While dropping the index: $@";

        query '', $log_id[1]->[0]->[0], $err, <<'SQL' unless $opt_dryrun;
UPDATE reindex.log
   SET status='failed to rename index or recreate constraints: ' || $2,
       tm_taken=now()-tstmp
 WHERE id=$1
SQL

        die "$err";
    };

    unless ($opt_validate) {
        query '', $log_id[1]->[0]->[0], $err, <<'SQL' unless $opt_dryrun;
UPDATE reindex.log
   SET status='done: constraints not validated',
       tm_taken=now()-tstmp
 WHERE id=$1
SQL

        return 1;
    }

    wait_for_concurrent_tx;

    my @not_validated;
    for my $con (@revalidate) {
        my ($conname, $quoted_conname, $nspname, $quoted_nspname, $contype, $condef, $rel, $frel, $matchtype, $key, $fkey) = @$con;
        my $sql;

        my $join_cond = '(' . join(', ', map { "b.$_" } @$fkey) . ')=(' . join(', ', map { "a.$_" } @$key) . ')';
        my $match = (
            $matchtype eq 's'    # MATCH SIMPLE
            ? 'AND '
            : $matchtype eq 'f'    # MATCH FULL
            ? ' OR '
            : do { ... }
        );                         # MATCH PARTIAL not yet implemented by PG
        $match = join($match, map { "a.$_ IS NOT NULL" } @$key);

        @rc = wquery "  Validate FK constraint $quoted_conname on $rel", $rel, $conname, <<"SQL";
UPDATE pg_catalog.pg_constraint
   SET convalidated = NOT EXISTS(SELECT 1
                                   FROM ONLY $rel a
                                   LEFT JOIN ONLY $frel b ON $join_cond
                                  WHERE b.$fkey->[0] IS NULL      -- inner join failed
                                    AND ($match))
 WHERE conrelid=\$1::regclass::oid
   AND conname=\$2
RETURNING convalidated
SQL
        unless ($opt_dryrun) {
            lg '    ' . ($rc[1]->[0]->[0] ? '' : 'NOT ') . "VALID\n";
            push @not_validated, $quoted_conname unless $rc[1]->[0]->[0];
        }
    }

    unless ($opt_dryrun) {
        if (@not_validated) {
            query '', $log_id[1]->[0]->[0], '[' . join('], [', @not_validated) . ']', <<'SQL';
UPDATE reindex.log
   SET status='failed: some constraints could not be validated: ',
       tm_taken=now()-tstmp
 WHERE id=$1
SQL
        } else {
            query '', $log_id[1]->[0]->[0], <<'SQL';
UPDATE reindex.log
   SET status='done',
       tm_taken=now()-tstmp
 WHERE id=$1
SQL
        }
    }

    return 1;
}

prepare unless defined $action and $action eq 'continue';

if (!defined $action or $action eq 'continue') {    ## no critic
    while (my @idx = next_index) {
        reindex @idx;
        query '', $idx[0], q{UPDATE reindex.worklist SET status='done' WHERE idx=$1};
    }
}

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
