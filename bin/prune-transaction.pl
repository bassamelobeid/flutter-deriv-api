#!perl

use strict;
use warnings;

use DBI;
use Getopt::Long;
use File::Path qw/make_path/;
use Time::HiRes ();

$|=1;
my $init = 'no';
my $outdir = '.';
my $cutoff_time;                   # before the beginning of time
my $cutoff_length;                 # infinity
my $aws_profile;

my $usage=<<'USAGE';
Usage:
 PGDATABASE=... PGHOST=... \
 prune_transaction.pl [--init[=only]] [--aws-profile=...] [--directory=...] \
                      [--time=...] [--length=...]

 All options can be abbreviated.

 This program deletes rows from the transaction table together with related
 rows from FMB and its child tables and QBV and replaces them with a summary
 transaction. It does that by means of the public.prune_transaction() function
 in the database.

 If the --init option is given, the program first sets up the following tables
 in the database:

     CREATE TABLE prune.worklist (
         account_id BIGINT PRIMARY KEY
     )

     CREATE TABLE prune.log (
         tmstmp     TIMESTAMP,
         account_id BIGINT,
         pruned     BIGINT,
         elapsed    DOUBLE PRECISION
     )

 The prune.worklist table is initialized with all existing account ids from
 transaction.account.

 If --init is given with the special value "only", the program ends after
 this initialization step. This allows the DBA to inspect and adjust the
 content of the worklist table before commencing the actual operation.

 Once the setup is done, accounts are removed from the worklist one by
 one and public.prune_transaction() is called for each removed account id.
 The values passed for the --time and --length options are passed to that
 function.

 When public.prune_transaction() returns a log row is inserted into the
 prune.log table. This allows the DBA to follow the overall progress.

 To speed things up multiple instances of this program can be run. Make
 sure to initialize the worklist only once in this case. Also, keep a close
 eye on the amount of WAL generated to not overload your WAL archiving or
 streaming replication.

 A good way to monitor the rate of WAL generation is this command:

   psql -XAqtF $'\t' service=vr01 <<'EOF' >vr-wal-rate.log
   WITH a AS (
       SELECT now()::timestamp(0)
            , round(pg_xlog_location_diff(
                        x, current_setting($$my.xlog_loc$$, true)::pg_lsn
                    )/(16*1024*1024), 2) AS wal_files_per_minute
            , set_config($$my.xlog_loc$$::text, x::text, false) AS xlog_pos
         FROM pg_current_xlog_location() as l(x)
   )
   SELECT *
     FROM a
    WHERE wal_files_per_minute IS NOT NULL
   \watch 60
   EOF

 It displays how many WAL is generated in units of 16MB (wal_segment_size)
 per minute. Usually this corresponds to the number of WAL files per minute.

 The public.prune_transaction() function returns all data it has removed from
 the database plus the one row it has inserted in JSON format. This information
 is compressed (gzip -9) and either written to a local disk or sent directly
 to S3. This is where the --directory option comes in. If it has the form of

     s3://bucket-name/directory

 then the data is sent to S3. Otherwise, this option specifies a local
 directory. The default value is the current working directory.

 If the data is sent to S3, the --aws-profile option can be used to specify
 a profile to use for the connection to S3. To send data to S3 the "aws"
 command line utility must be available and configured.

 There is no option to specify which database to connect to. This is done via
 the standard Postgres environment variables. For more information see:

     https://www.postgresql.org/docs/current/libpq-envars.html
USAGE

GetOptions ('init:s'=>\$init, 'directory=s'=>\$outdir,
            'aws-profile=s'=>\$aws_profile,
            'time=s'=>\$cutoff_time, 'length=s'=>\$cutoff_length)
    or die $usage;

my $init_always_sql = <<'SQL';
SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ
SQL

my $init_sql = <<'SQL';
BEGIN

ALTER EVENT TRIGGER aaa_prevent_drop DISABLE

DROP SCHEMA IF EXISTS prune CASCADE

ALTER EVENT TRIGGER aaa_prevent_drop ENABLE

COMMIT

CREATE SCHEMA prune

CREATE TABLE prune.worklist (
    account_id BIGINT PRIMARY KEY
)

CREATE TABLE prune.log (
    tmstmp     TIMESTAMP,
    account_id BIGINT,
    pruned     BIGINT,
    elapsed    DOUBLE PRECISION
)

INSERT INTO prune.worklist
SELECT id FROM transaction.account
SQL

my $prune_cursor = <<'SQL';
DECLARE prune_csr CURSOR WITHOUT HOLD FOR
SELECT op FROM public.prune_transaction($1::BIGINT, $2::TIMESTAMP, $3::BIGINT)
SQL

my $prune_fetch = <<'SQL';
FETCH 1000 FROM prune_csr
SQL

my $prune_close = <<'SQL';
CLOSE prune_csr
SQL

my ($db, $next_account, $log_it);
sub opendb {
    $db = DBI->connect('dbi:Pg:', undef, undef, {RaiseError=>1, PrintError=>0});

    for my $sql (split /\n\n/, $init_always_sql) {
        $db->do($sql);
    }

    $next_account = $db->prepare(<<'SQL');
WITH a AS (
    SELECT account_id
      FROM prune.worklist
       FOR UPDATE SKIP LOCKED
     LIMIT 1
)
DELETE FROM prune.worklist AS b
 USING a
 WHERE b.account_id = a.account_id
RETURNING *
SQL

    $log_it = $db->prepare(<<'SQL');
INSERT INTO prune.log (tmstmp, account_id, pruned, elapsed)
VALUES (now()::TIMESTAMP, $1::BIGINT, $2::BIGINT, $3::DOUBLE PRECISION)
SQL
}

opendb;
if ($init ne 'no') {
    for my $sql (split /\n\n/, $init_sql) {
        $db->do($sql);
    }
}
exit 0 if $init eq 'only';

my @transfer_cmd;
if ($outdir =~ m!^s3://([^/]+)/(.+?)/*$!) {
    my $bucket = $1;
    my $key = $2;
    $outdir = "s3://$bucket/$key"; # just to make sure there is no trailing slash
    my @cmd = qw/aws s3api/;
    push @cmd, '--profile', $aws_profile if $aws_profile;
    push @cmd, qw/put-object --bucket/, $bucket, '--key', $key.'/';
    open my $fh, '-|', @cmd
        or die "Cannot create pipe (@cmd): $!\n";
    1 while readline $fh;
    close $fh
        or die ($!+0
                ? "Error closing pipe (@cmd): $!\n"
                : "@cmd failed: rc=$?\n");
    # need to use bash here /bin/sh might not have pipefail
    @transfer_cmd = (qw!/bin/bash -o pipefail -c!,
                     'gzip -9 | aws s3' . ($aws_profile ? " --profile '$aws_profile'" : '') .
                     ' --quiet cp - "$1"',
                     '--');
} else {
    -d $outdir or make_path $outdir;
    @transfer_cmd = (qw!/bin/sh -c!, 'exec gzip -9 > "$1" && sync "$1"', '--');
}

sub prune {
    my $accid = shift;

    my $start = [Time::HiRes::gettimeofday];
    my $fn = "$outdir/acc_$accid-tm_$start->[0].json.gz";
    my $fh;
    my $n = 0;

    $db->do($prune_cursor, undef, $accid, $cutoff_time, $cutoff_length);
    while (1) {
	my $sth = $db->prepare($prune_fetch);
	$sth->execute;
	last if 0 == $sth->rows;
	while (my $row = $sth->fetchrow_arrayref) {
	        unless ($n) {           # open the file only if needed
		    open $fh, '|-', @transfer_cmd, $fn
			    or die "Cannot open pipe to gzip to write $fn: $!\n";
		    binmode $fh, 'encoding(utf-8)';
		        }

		    print $fh $row->[0], "\n"
			or die "Cannot write to pipe to gzip to write $outdir/$accid.gz: $!\n";
		    $n++;
		}
    }
    $db->do($prune_close);

    if ($n) {
        close $fh
            or die ($!+0
                    ? "While closing pipe to gzip to write $outdir/$accid.gz: $!\n"
                    : "Gzip $outdir/$accid.gz failed (rc=$?)\n");

        print "$$: Pruned account $accid of $n transactions\n";
    } else {
        print "$$: No changes to account $accid\n";
    }
    $log_it->execute($accid, $n, Time::HiRes::tv_interval($start));

    return 1;                   # success
}

sub txn {
    $db->begin_work;
    $next_account->execute;
    my $accid = $next_account->fetchall_arrayref;
    unless (defined $accid and @$accid) {   # all done
        $db->rollback;
        return 0;
    }
    if (prune $accid->[0]->[0]) {
        $db->commit;
    } else {
        $db->rollback;
    }

    return 1;                   # did something
}

sub once {
    my $res = eval{txn};
    return $res if defined $res;
    warn $@ if $@;
    eval {$db->rollback};
    eval {$db->disconnect};
    undef $db;
    sleep 1;
    eval {opendb};
    return 1;
}

1 while once;
