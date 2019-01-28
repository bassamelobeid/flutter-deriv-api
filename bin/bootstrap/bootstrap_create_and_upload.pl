#!/usr/bin/env perl

## Create a "bootstrap" version of a database and ship to S3
## Some of the larger tables are excluded, or only copied in part
## The data is loaded into a temporary database, then cleaned up.
## Then we take a base backup, compress it, encrypt it, and ship it to S3

use strict;
use warnings;
use Getopt::Long qw( GetOptions );
use Sys::Hostname qw( hostname );
use File::Path qw( make_path remove_tree );
use Path::Tiny qw( path );
use Time::Duration qw( duration );
use Format::Util::Numbers qw( commas );

our $VERSION = '3.12';

my $USAGE = "Usage: $0 --db=<cr or vr> [--time_limit=X] [--verbose]\n";

my %opt = ();

GetOptions(\%opt, 'db=s', 'help', 'verbose+', 'time_limit|time-limit=s', 'force',)
    or exit 1;

if ($opt{help}) {
    print "$USAGE\n";
    exit 0;
}

my $db      = $opt{db}      // die $USAGE;
my $verbose = $opt{verbose} // 0;
my $force   = $opt{force}   // 0;

## Are we running on a devbox?
my $devbox = hostname =~ /^qa/ ? 1 : 0;

## Setup logging:
my $ideal_log_dir = '/var/log/bootstrap';
my $log_dir       = -e $ideal_log_dir ? $ideal_log_dir : '/tmp';
my $log_file      = path("$log_dir/bootstrap.log");
my $log_messages  = '';

sub logit {

    my $message = shift;
    chomp $message;
    $message .= "\n";

    $verbose and print $message;
    $log_messages .= $message;
    $log_file->append($message);

    return;
}

END {
    ## If we did not exit cleanly, we want cron to get all the verbose information
    warn $log_messages if defined $log_messages and $? and not $verbose;
}

## Globals we set early on:
my ($service_name, $database_name, $temp_database_name, $time_limit);
my ($basedir,      $datadir,       $socketdir,          $pgbindir);
my ($psql_local,   $psql_remote,   $pg_dump_local,      $pg_dump_remote);
my ($aws, $s3_profile_name, $s3_bucket_name);

logit "Starting $0 version $VERSION\n";
my $script_start_time = time();
logit sprintf "--> Time:                         %s\n", scalar localtime;
logit sprintf "--> Running on devbox?:           %s\n", $devbox ? 'yes' : 'no';

my %info = (

    server => {
        cr => {
            service_name       => 'cr03',
            default_time_limit => '2 days',
            database_name      => 'regentmarkets',
        },
        vr => {
            service_name       => 'vr04',
            default_time_limit => '1 hour',
            database_name      => 'regentmarkets',
        },
    },

    excluded_schemas => ['audit',],

    special_tables => {
        'bet.digit_bet'                        => 'financial_market_bet_id',
        'bet.financial_market_bet'             => 'fmb id',
        'bet.higher_lower_bet'                 => 'financial_market_bet_id',
        'bet.range_bet'                        => 'financial_market_bet_id',
        'bet.run_bet'                          => 'financial_market_bet_id',
        'bet.touch_bet'                        => 'financial_market_bet_id',
        'betonmarkets.login_history'           => 'skip',
        'transaction.transaction'              => 'txn id',
        'transaction.firsts'                   => 'transaction_id',
        'data_collection.quants_bet_variables' => 'transaction_id',
    },

);

## Set database information, and determine how far back we are slicing
get_database_info();

## Confirm everything works as expected before starting the dumps
sanity_checks();

## Create our temporary Postgres cluster
create_temp_cluster();

## Get the global Postgres information (i.e. roles)
fetch_postgres_globals();

## Get the minimal schema via pg_dump --section=pre-data
fetch_postgres_pre_data();

## We only get some (or none) of the larger tables
fetch_postgres_special_tables();

## Grab everything except excluded schemas and tables (this takes the longest amount of time)
fetch_postgres_data();

## Create indexes and foreign keys via pg_dump --section=post-data, and run analyze
fetch_postgres_post_data();

## Fix up any problems caused by the partial tables
adjust_temp_cluster();

## Dump, compress, encrypt, and ship to S3
dump_and_ship();

## Shut down and remove the temp cluster
remove_temp_cluster("$basedir/temp_bootstrap_cluster");

my $total_time = duration(time() - $script_start_time);
logit "Complete. Total time: $total_time\n";

exit;

sub run_command {

    ## Shell out and run a command, return the result

    my $command = shift // "Need a command";

    $verbose > 1 and logit "ABOUT TO RUN: $command\n";

    my $result = qx{ $command 2>&1 };
    chomp $result;
    $verbose > 1 and logit "RESULT: $result\n";

    return $result;

} ## end of run_command

sub get_database_info {

    ## Determine database name, service name, and the time limit

    if (!exists $info{server}{$db}) {
        my $list = join ', ' => sort keys %{$info{server}};
        die qq{Sorry, but '$db' does not seem to be a valid choice. Must be one of: $list\n};
    }

    $service_name  = $info{server}{$db}{service_name}  or die qq{Could not determine service file name\n};
    $database_name = $info{server}{$db}{database_name} or die qq{Could not determine database name\n};
    $temp_database_name = "bootstrap_{$db}_$database_name";
    $time_limit = $info{server}{$db}{default_time_limit} or die qq{Could not find default time limit for "$db"\n};

    if (exists $opt{time_limit}) {
        $time_limit = $opt{time_limit};
    }

    ## Override for devboxes. Someday this will not be needed!
    if ($devbox) {
        $service_name = 'clientdb-pgadmin';
    }

    logit "--> Database:                     $db\n";
    logit "--> Service name:                 $service_name\n";
    logit "--> Time range:                   $time_limit\n";
    logit "--> Database name:                $database_name\n";
    logit "--> Temp database name:           $temp_database_name\n";

    return;

} ## end of get_database_info

sub sanity_checks {

    ## Do our best to make sure we fail early if important things are missing

    $psql_remote = qq{psql -AX -qt service=$service_name};

    ## It's really best to run this script against a hot standby server
    my $result = run_command(qq{$psql_remote -c "SELECT pg_is_in_recovery()"});
    $result =~ /^[tf]$/ or die "Invalid response from pg_is_in_recovery: $result\n";
    if (!$devbox && $result eq 'f') {
        $force or die qq{Must run on a replica (or use the --force option)\n};
        logit "--> Forcing run on a non-replica database\n";
    }

    ## Warn if a non-zero statement_timeout is set
    $result = run_command(qq{$psql_remote -c "SHOW statement_timeout"});
    $result =~ /^\d+$/ or die qq{Invalid result for statement_timeout: $result\n};
    if ($result ne '0') {
        logit "WARNING: statement_timeout is set to $result!\n";
    }

    ## Grab the version
    $result = run_command(qq{ $psql_remote -c 'SELECT version()' });
    $result =~ s/, compiled.*//;
    logit "--> Postgres version:             $result\n";
    if ($result !~ /(\d+)\.(\d+)/) {
        die 'Could not determine the Postgres version';
    }
    my ($version, $v2) = ($1, $2);
    if ($version < 10) {
        $version = "$version.$v2";
    }

    $pgbindir       = "/usr/lib/postgresql/$version/bin";
    $psql_remote    = qq{$pgbindir/psql -AX -qt service=$service_name};
    $pg_dump_remote = qq{$pgbindir/pg_dump service="$service_name" --lock-wait-timeout=60};

    $basedir = "$ENV{HOME}/bootstrap";
    if (!-d $basedir) {
        mkdir $basedir, 0700;
        logit "--> Created directory:            $basedir\n";
    }

    ## No S3 on devboxes
    if ($devbox) {
        logit "--> S3 tests skipped:             yes\n";
        return;
    }

    ## GPG password file must exist
    if (!-f "$ENV{HOME}/.bootstrap.password") {
        die qq{Cannot proceed without a GPG password file\n};
    }

    ## The aws program must be available
    $aws    = '/usr/local/bin/aws';
    $result = run_command("$aws help");
    if ($result !~ /ec2/) {
        die qq{Cannot proceed without 'aws' command\n};
    }

    ## S3 profile, bucket, and 'bootstrap' directory must exist
    $s3_profile_name = "db-pgarchive-$db";
    $s3_bucket_name  = "binary-pgarchive-$db";

    logit "--> S3 profile name:              $s3_profile_name\n";
    logit "--> S3 bucket name:               $s3_bucket_name\n";

    $result = run_command(qq{$aws s3 --profile "$s3_profile_name" ls s3://$s3_bucket_name}) // '?';
    if ($result =~ /profile.+could not be found/) {
        die qq{S3 profile "$s3_profile_name" was not found: check the ~/.aws/config file\n};
    }
    if ($result =~ /NoSuchBucket/) {
        die qq{S3 bucket "$s3_bucket_name" was not found\n};
    }
    if ($result !~ m{\bbootstrap/}) {
        die qq{Could not find directory 'bootstrap' in the S3 bucket "$s3_bucket_name": $result\n};
    }

    ## Make sure we can write to S3
    my $testfile = 'bootstrap.testfile';
    path($testfile)->spew("Test file for bootstrap uploading. Feel free to delete.\n");
    $result = run_command(qq{$aws s3 --profile "$s3_profile_name" cp $testfile s3://$s3_bucket_name/bootstrap/}) // '?';
    if ($result !~ m{upload: ./$testfile to s3://$s3_bucket_name/bootstrap/$testfile}) {
        die qq{Failed to upload test file:\n $result\n};
    }
    unlink $testfile;

    logit "--> S3 test file uploaded:        $testfile\n";

    return;

} ## end of sanity_checks

sub create_temp_cluster {

    ## Create a very private and very temporary cluster
    my $dirname = "$basedir/temp_bootstrap_cluster";
    logit "--> Temp cluster dir:             $dirname\n";

    ## Just in case, remove any older version:
    remove_temp_cluster($dirname);

    $datadir   = "$dirname/data";
    $socketdir = "$dirname/socket";
    make_path($socketdir);

    $psql_local =
        qq{$pgbindir/psql -AX -qt --host "$socketdir" --port 7777 --username bootstrap --dbname $temp_database_name --set ON_ERROR_STOP=on --single-transaction};

    $pg_dump_local = qq{$pgbindir/pg_dump -h $socketdir -p 7777 -d $temp_database_name };

    logit "--> Temp data directory:          $datadir\n";
    logit "--> Temp socket directory:        $socketdir\n";

    my $result = run_command(qq{$pgbindir/initdb -D "$datadir" -A trust -U bootstrap});
    if ($result !~ /Success/) {
        die "initdb seems to have failed: $result\n";
    }

    ## Custom things for safety, speed, and base backup capability
    path("$datadir/postgresql.conf")->append(
        <<EOT
port                        = 7777
fsync                       = off
autovacuum                  = off
maintenance_work_mem        = 1GB
logging_collector           = on
log_filename                = 'bootstrap.log'
log_min_duration_statement  = 0
unix_socket_directories     = '$socketdir'
wal_level                   = replica
max_wal_senders             = 5
shared_preload_libraries    = 'pglogical'
EOT
    );
    logit "--> Adjusted:                     $datadir/postgresql.conf\n";

    path("$datadir/pg_hba.conf")->append("local  replication  $ENV{LOGNAME}  trust");
    logit "--> Adjusted:                     $datadir/pg_hba.conf\n";

    $result = run_command(qq{$pgbindir/pg_ctl start -w -D "$datadir" -l logfile});
    if ($result !~ /waiting for server/) {
        die "pg_ctl start failed: got $result";
    }

    ## Create the new database
    $result = run_command(qq{$pgbindir/createdb -h $socketdir -p 7777 -U bootstrap $temp_database_name});

    return;

} ## end of create_temp_cluster

sub remove_temp_cluster {

    ## Remove our temporary Postgres cluster

    my $dirname = shift or die;

    return if !-e $dirname;

    my $pidfile = "$dirname/data/postmaster.pid";
    if (-e $pidfile) {
        run_command(qq{$pgbindir/pg_ctl stop --silent -w -D "$dirname/data" --m fast});
    }

    $dirname =~ /temp/ or die "Safety check failed: refusing to remove $dirname\n";
    my $rmfail;
    remove_tree($dirname, {error => \$rmfail});

    return;

} ## end of remove_temp_cluster

sub fetch_postgres_globals {

    ## Get the Postgres "global" information and put into the test cluster

    my $result = run_command(qq{$pgbindir/pg_dumpall -d service="$service_name" --globals | $psql_local -f -});
    length $result and die qq{Failed to load global info into temp cluster: $result\n};
    logit "--> Applied:                      pg_dumpall --globals\n";

    return;

} ## end of fetch_postgres_globals

sub fetch_postgres_pre_data {

    ## Get all the "pre" data schema information and load directly into the test cluster

    my $result = run_command(qq{$pg_dump_remote --section=pre-data | $psql_local -f -});
    length $result and die qq{Loading pre-data section into temp cluster failed: $result\n};
    logit "--> Applied:                      pg_dump --section=pre-data\n";

    return;

} ## end of fetch_postgres_post_data

sub fetch_postgres_data {

    ## Grab the data of all tables except for a few excluded ones, and put into the temp cluster

    my $no_schemas = '';
    if (@{$info{excluded_schemas}}) {
        $no_schemas = join ' ', map { qq{-N "$_"} } sort @{$info{excluded_schemas}};
    }

    my $no_tables = '';
    if (keys %{$info{special_tables}}) {
        $no_tables = join ' ', map { qq{-T "$_"} } sort keys %{$info{special_tables}};
    }

    my $start_time = time();
    my $result     = run_command(qq{$pg_dump_remote --section=data $no_schemas $no_tables | $psql_local -f - });
    $result =~ /[a-z]/ and die qq{Load of data section failed: $result\n};

    logit sprintf "--> Time to copy --section=data:  %s\n", duration(time() - $start_time);

    return;

} ## end of fetch_postgres_data

sub fetch_postgres_post_data {

    ## Get all the "post" data schema information and load directly into the test cluster

    my $result = run_command(qq{$pg_dump_remote --section=post-data | $psql_local -f -});
    length $result and die qq{Loading post-data section into temp custer failed: $result\n};
    logit "--> Applied:                      pg_dump --section=post-data\n";

    $result = run_command(qq{$psql_local -c 'ANALYZE'});
    logit "--> Applied:                      ANALYZE\n";

    return;

} ## end of fetch_postgres_post_data

sub fetch_postgres_special_tables {

    ## Carefully dump only part of some tables

    ## We will need to get a range for transaction IDs:
    my %txn;
    for my $type ('Low', 'High') {
        my $SQL =
            $type eq 'High'
            ? 'SELECT MAX(id) FROM transaction.transaction'
            : qq{SELECT id FROM transaction.transaction WHERE transaction_time >= (now() - '$time_limit'::interval) ORDER BY transaction_time ASC limit 1};
        my $id = run_command(qq{ $psql_remote -c "$SQL" });
        if (!length $id && $devbox) {
            ## It is very likely devboxes will have no transactions at all
            $id = $type eq 'High' ? 999999 : 123;
        } elsif ($id !~ /^\d+$/) {
            die "Invalid result from $SQL\n$id\n";
        }

        logit sprintf "--> %s transaction ID:          %s%s\n", $type, $type eq 'Low' ? ' ' : '', commas($id);
        $txn{$type} = $id;
    }

    my $total_txns = $txn{High} - $txn{Low};
    logit sprintf "--> Potential IDs:                %*s\n", length(commas($txn{Low})), commas($total_txns);

    for my $table (sort grep { $info{special_tables}{$_} ne 'skip' } keys %{$info{special_tables}}) {

        my $SQL;
        my $type = $info{special_tables}{$table};
        if ($type eq 'financial_market_bet_id') {
            $SQL = "SELECT x.* FROM $table x WHERE EXISTS (SELECT 1 FROM transaction.transaction t
                 WHERE t.financial_market_bet_id = x.financial_market_bet_id AND t.id BETWEEN $txn{Low} AND $txn{High})";
        } elsif ($type eq 'fmb id') {
            $SQL = "SELECT x.* FROM $table x WHERE EXISTS (SELECT 1 FROM transaction.transaction t
                 WHERE t.financial_market_bet_id = x.id AND t.id BETWEEN $txn{Low} AND $txn{High})";
        } elsif ($type eq 'txn id') {
            $SQL = "SELECT * FROM $table WHERE id BETWEEN $txn{Low} AND $txn{High}";
        } elsif ($type eq 'transaction_id') {
            $SQL = "SELECT * FROM $table WHERE transaction_id BETWEEN $txn{Low} AND $txn{High}";
        } else {
            die qq{Do not know how to handle type "$type" for relation "$table"!\n};
        }

        my $start_time = time();
        my $result     = run_command(qq{ $psql_remote -c "COPY ($SQL) TO STDOUT" | $psql_local -c "COPY $table FROM STDIN" -f - });
        length $result and die qq{Load of table $table failed: $result\n};

        logit sprintf "--> Applied:                      %s (Time: %s)\n", $table, duration(time() - $start_time);
    }

    for my $table (sort grep { $info{special_tables}{$_} eq 'skip' } keys %{$info{special_tables}}) {
        logit "--> Skipping all data for table $table\n";
    }

    return;

} ## end of fetch_postgres_special_tables

sub adjust_temp_cluster {

    ## Get the transaction table whipped into shape

    my $bootstrap_script = <<'EOT';
CREATE OR REPLACE FUNCTION bootstrap_add_dummy_transaction (p_account_id BIGINT)
RETURNS VOID
VOLATILE LANGUAGE plpgsql AS $def$
  DECLARE
    v_account transaction.account;
    v_sum NUMERIC;
    v_new_amount NUMERIC;
  BEGIN
    SELECT * FROM transaction.account WHERE id = p_account_id INTO v_account;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Invalid account id: %', p_account_id;
    END IF;

    -- Short-circuit if this account has had no activity
    IF v_account.last_modified IS NULL AND v_account.balance = 0 THEN
      RETURN;
    END IF;

  SELECT SUM(amount) FROM transaction.transaction WHERE account_id = p_account_id INTO v_sum;
  RAISE DEBUG 'Sum and balance for %: % %', p_account_id, v_sum, v_account.balance;
  IF v_sum = v_account.balance THEN
    RETURN;
  END IF;

  SELECT v_account.balance - COALESCE(v_sum,0) INTO v_new_amount;
  INSERT INTO bootstrap_transaction_entries
    (id, action_type, account_id,   amount, balance_after, transaction_time,   quantity, staff_loginid, referrer_type)
  VALUES
    (nextval('sequences.transaction_serial'), 'bootstrap_adjustment', p_account_id,
     v_new_amount, v_new_amount, '1970-01-01',
     1, 'bootstrap', 'adjustment');
  RETURN;
END
$def$;

-- Temporary table to hold the new dummy rows:
CREATE TABLE bootstrap_transaction_entries (LIKE transaction.transaction);

-- Temporary indexes to speed things up
CREATE INDEX bootstrap_index_1 ON transaction.transaction (account_id);
CREATE INDEX bootstrap_index_2 ON transaction.account (id);

-- Rewrite the transaction table constraints to allow action_type to be 'bootstrap_adjustment'
ALTER TABLE transaction.transaction
  DROP CONSTRAINT chk_transaction_field_action_type,
  DROP CONSTRAINT chk_amount_sign_based_on_action_type,
  DROP CONSTRAINT chk_referrer_id_based_on_referrer_type,
  DROP CONSTRAINT chk_transaction_field_referrer_type,
  DROP CONSTRAINT quantity_gt_0;

-- Adjust session_replication_role so the transaction table triggers do not fire
SET session_replication_role = 'replica';

-- On a devbox, this takes about 7 minutes when transaction table is 150 million rows
DO $$ BEGIN perform bootstrap_add_dummy_transaction(id) FROM transaction.account; END $$;

-- On a devbox, this takes about 7 minutes
INSERT INTO transaction.transaction SELECT * FROM bootstrap_transaction_entries;

-- Cleanup to prevent duplicate entries
TRUNCATE TABLE bootstrap_transaction_entries;

-- Very important to say NOT VALID, or this takes forever
ALTER TABLE transaction.transaction
  ADD CONSTRAINT chk_transaction_field_action_type CHECK (
     action_type IN ('buy','sell','deposit','withdrawal','adjustment','virtual_credit','bootstrap_adjustment')
  ) NOT VALID,
  ADD CONSTRAINT chk_amount_sign_based_on_action_type CHECK (
     action_type = 'bootstrap_adjustment'
     OR (action_type = 'deposit' AND amount >= 0)
     OR (action_type = 'withdrawal' AND amount <= 0)
     OR (action_type = 'buy' AND amount <= 0)
     OR (action_type = 'sell' AND amount >= 0)
     OR (action_type = 'virtual_credit' AND amount >= 0)
  ) NOT VALID,
  ADD CONSTRAINT chk_referrer_id_based_on_referrer_type CHECK (
     (referrer_type = 'payment' AND payment_id IS NOT NULL)
     OR referrer_type = 'financial_market_bet'
     OR action_type = 'virtual_credit'
     OR action_type = 'bootstrap_adjustment'
  ) NOT VALID,
  ADD CONSTRAINT chk_transaction_field_referrer_type CHECK (
    referrer_type IN ('financial_market_bet', 'payment', 'adjustment')
  ) NOT VALID,
  ADD CONSTRAINT quantity_gt_0 CHECK (
    quantity > 0 IS TRUE
  ) NOT VALID;

-- Cleanup
DROP INDEX transaction.bootstrap_index_1;
DROP INDEX transaction.bootstrap_index_2;
DROP TABLE bootstrap_transaction_entries;

EOT

    my $tempfile = Path::Tiny->tempfile();
    $tempfile->spew($bootstrap_script);
    my $result = run_command(qq{ $psql_local -f $tempfile });
    length $result and die qq{Failed to run bootstrap script: $result};
    logit "--> Ran script:                   bootstrap_post_load_adjustments\n";

    return;

} ## end of adjust_temp_cluster

sub dump_and_ship {

    ## Run pg_basebackup on our local cluster in tarfile format
    ## Compress it, encrypt it, and ship it off to S3

    if ($devbox) {
        logit "--> Skipping S4 upload:           (devbox)\n";
        return;
    }

    my $basebackup = qq{pg_basebackup --host "$socketdir" --port 7777 --format t --xlog --label=bootstrap --pgdata - };
    my $compress   = qq{ xz -0 --threads 2 };
    my $encrypt =
        qq{ gpg --options /dev/null --quiet --symmetric --batch --passphrase-file ~/.bootstrap.password --compress-level 0 --cipher-algo AES};
    my $backup_name = "bootstrap.basebackup.$db.tar.xz.gpg";
    my $s3          = qq{$aws s3 --quiet --profile $s3_profile_name cp - s3://$s3_bucket_name/bootstrap/$backup_name };

    my $result = run_command(" $basebackup | $compress | $encrypt | $s3 ");
    length $result and die qq{base backup failed: $result};
    logit "--> Uploaded to S3:               $backup_name\n";

    ## Check it out and show the size
    $result = run_command(qq{ $aws s3 --profile $s3_profile_name ls s3://$s3_bucket_name/bootstrap/$backup_name });
    if ($result =~ /(\d+) $backup_name/) {
        logit sprintf "--> Upload size:                  %s\n", pretty_size($1);
    } else {
        logit "Could not determine size. aws s3 ls said: $result\n";
    }

    return;

} ## end of dump_and_ship

sub pretty_size {

    ## Transform number of bytes to a SI display similar to Postgres' format

    my $bytes = shift;

    return '' if !defined $bytes;

    return '0 bytes' if $bytes == 0;

    my @unit = qw/bytes kB MB GB TB PB EB YB ZB/;
    my $idx  = int(log($bytes) / log(1024));
    $bytes >>= 10 * $idx if $idx;

    return "$bytes $unit[$idx]";

} ## end of pretty_size
