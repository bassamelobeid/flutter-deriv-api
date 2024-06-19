#!/usr/bin/env perl
# -*-mode:cperl; indent-tabs-mode: nil-*-

## Pail_n_mail
## 1. Scoop up interesting stats from the databases and mail them out
## 2. Scoop up all stats and move to a central server

use strict;
use warnings;
use autodie;
use Data::Dumper;
use CGI qw/ escapeHTML /;
use DBI;
use Getopt::Long;
use Text::Wrap;
use File::Temp;
use File::Basename;

our $VERSION = '1.10';

## Don't hang around very long - these hosts should be reachable quickly
$ENV{PGCONNECT_TIMEOUT} = 13;

## Few constants
my $PSS_TABLE  = 'pgss_stats';
my $PSSQ_TABLE = 'pgss_query';
my $MAILTO     = '';
my $MAILFROM   = '';

my $SKIP_HOSTS = "$ENV{HOME}/.pnm_skip_hosts.conf"
    ;    # this file will have 'chronicle|chronicle01|chronicle02|crypto01|crypto03|mf04|mlt04|mx04|vr03|feed10|feed06|mlt06|mx06|dw02|dw04|dw05|
open my $fh, '<', $SKIP_HOSTS;    # vrdw02|vrdw04|vrdw05|admin|feed_write' for now, addition and substraction can later be made.
$SKIP_HOSTS = <$fh>;

## Options and their defaults
my %arg = (

    ## Obvious ones
    debug   => 0,
    dryrun  => 0,
    help    => 0,
    quiet   => 0,
    verbose => 0,
    version => 0,

    ## What are we trying to do? :)
    action => 'store_stats',

    ## Minimum mean execution time
    min_mean_time => 3000,

    ## Minimum times query is called since last reset
    min_calls => 30,

    ## How big of a query string to pull back
    max_string => 1200,

    ## How many items to show
    count => 10,

    ## How far back to go
    timeback => '12 hours',

    ## Who to send it to
    mailto => $MAILTO,

    ## Limit to hosts matching this regex.
    hosts => '0',

    ## Some hosts should always be skipped

    skiphosts => $SKIP_HOSTS,

    ## Show all known hosts and exit
    showhosts => '',

    ## How many characters to wrap long queries at
    querywrap => 80,

    ## Do we show the database name
    showdbname => 0,

    ## Limit to this many rows only (mostly used for debugging)
    limit => 0,

    ## Don't actually send email or commit any db changes
    dryrun => 0,

);

## Main hash containing information for each host
my %hostinfo;

## Map out which queryids are already pulled in
my %known_queryid;

## Global statement handles
my ($central_add_stat, $central_add_query);

## Important fields
my @pss_fields = qw/ queryid
    calls total_time min_time max_time mean_time stddev_time rows
    shared_blks_hit shared_blks_read shared_blks_dirtied shared_blks_written
    local_blks_hit local_blks_read local_blks_dirtied local_blks_written
    temp_blks_read temp_blks_written
    /;

## Parse arguments and set a few global vars
setup();

## Parse the Postgres service file to build a list of hosts
load_hosts();

## Move all stats from remote databases to a central one
if ($arg{action} eq 'store_stats') {
    store_all_stats();
}
## Send an alert email about important queries
elsif ($arg{action} eq 'email_stats') {
    stats_email();
} else {
    die "Unknown action: $arg{action}\n";
}

exit;

## Down below here are only subs

sub store_all_stats {

    ## Move stats from remote hosts to a central database

    ## Connect to the central database and prepare some queries
    my $dsn       = "dbi:Pg:service=admin";
    my $centraldb = DBI->connect(
        $dsn, '', '',
        {
            AutoCommit => 0,
            RaiseError => 1,
            PrintError => 0
        });

    ## Grab all the known queryids. This is not a very large list.
    my $SQL                  = "SELECT queryid FROM $PSSQ_TABLE";
    my $central_get_queryids = $centraldb->prepare_cached($SQL);
    $central_get_queryids->execute();
    for my $row (@{$central_get_queryids->fetchall_arrayref()}) {
        $known_queryid{$row->[0]} = 1;
    }

    ## Store query stats into the central database, based on the queryid
    $SQL = sprintf 'INSERT INTO %s(sampletime, host, %s) VALUES (?,?,%s)', $PSS_TABLE, (join ',' => sort @pss_fields), ('?,' x @pss_fields);
    $SQL =~ s/,\)/)/;
    $central_add_stat = $centraldb->prepare_cached($SQL);

    ## Store query strings into the central database
    $SQL               = "INSERT INTO $PSSQ_TABLE(queryid, username, dbname, query) VALUES (?,?,?,?)";
    $central_add_query = $centraldb->prepare_cached($SQL);

    ## For each host we care about, store their stats
    for my $host (sort keys %hostinfo) {
        next if exists $hostinfo{$host}{skip};
        store_remote_stats($host, $centraldb);
    }

    $arg{verbose} and print "> Finished: disonnecting from central database\n";

    $centraldb->disconnect();

    exit 0;

} ## end of store_all_stats

sub store_remote_stats {

    ## Transfer pg_stat_statements information from a single remote databases to a central one
    ## Arguments: two
    ## 1. Remote host name
    ## 2. Central database handle
    ## Returns: undef

    my $remote_name = shift or die 'Remote host name required!';

    my $centraldb = shift;

    if (!defined $centraldb or !ref $centraldb) {
        die 'Central database database handle required!';
    }

    $arg{verbose} and print "> Storing stats from remote host $remote_name\n";

    my $dsn = "dbi:Pg:service=$remote_name";
    my $remotedb;
    eval { $remotedb = DBI->connect($dsn, '', '', {AutoCommit => 0, RaiseError => 0, PrintError => 1}); };
    if (!defined $remotedb) {
        warn "Connection to $remote_name failed: $@\n";
        return;
    }

    ## Grab the time from the remote database
    $remotedb->do(q{SET TIMEZONE = 'UTC'});
    my $remote_time = $remotedb->selectall_arrayref('SELECT now()')->[0][0];

    ## Grab the remote server_version
    my $remote_server_version =
        $remotedb->selectall_arrayref(q{SELECT substring(setting from '^(?:\d\.\d\d?|\d+)') FROM pg_settings WHERE name='server_version'})->[0][0];

    ## Quick database mapping, as pg_stat_statements only spits out database OIDs
    my %dbmap;
    my $SQL = 'SELECT oid, datname FROM pg_database';
    for my $row (@{$remotedb->selectall_arrayref($SQL)}) {
        $dbmap{$row->[0]} = $row->[1];
    }

    ## Grab everything from the table (excluding query strings)
    ## Note: null queryids indicates a database with query info we cannot view

    if ($remote_server_version == '13') {
        $SQL = q{ 
SELECT queryid
     , calls
     , total_exec_time
     , min_exec_time
     , max_exec_time
     , mean_exec_time
     , stddev_exec_time
     , rows
     , shared_blks_hit
     , shared_blks_read
     , shared_blks_dirtied
     , shared_blks_written
     , local_blks_hit
     , local_blks_read
     , local_blks_dirtied
     , local_blks_written
     , temp_blks_read
     , temp_blks_written
  FROM pg_stat_statements(false) 
 WHERE queryid IS NOT NULL 
};
        ## Need to reset @pss_fields here if server_version = 13
        @pss_fields = qw/ queryid
            calls total_exec_time min_exec_time max_exec_time mean_exec_time stddev_exec_time rows
            shared_blks_hit shared_blks_read shared_blks_dirtied shared_blks_written
            local_blks_hit local_blks_read local_blks_dirtied local_blks_written
            temp_blks_read temp_blks_written
            /;
    } else {
        $SQL = q{ 
SELECT queryid
     , calls
     , total_time
     , min_time
     , max_time
     , mean_time
     , stddev_time
     , rows
     , shared_blks_hit
     , shared_blks_read
     , shared_blks_dirtied
     , shared_blks_written
     , local_blks_hit
     , local_blks_read
     , local_blks_dirtied
     , local_blks_written
     , temp_blks_read
     , temp_blks_written
  FROM pg_stat_statements(false) 
 WHERE queryid IS NOT NULL 
};
        ## Need to reset @pss_fields here if server_version < 13
        @pss_fields = qw/ queryid
            calls total_time min_time max_time mean_time stddev_time rows
            shared_blks_hit shared_blks_read shared_blks_dirtied shared_blks_written
            local_blks_hit local_blks_read local_blks_dirtied local_blks_written
            temp_blks_read temp_blks_written
            /;
    }

    my $remote_get_stats = $remotedb->prepare($SQL);

    ## Query strings get pulled separately
    $SQL = q{
SELECT queryid, userid::regrole AS username, dbid, query 
  FROM pg_stat_statements(true) 
 WHERE queryid = ANY(?)
};
    my $remote_get_query = $remotedb->prepare($SQL);

    ## First, we pull all queryids and their stats
    my $count = $remote_get_stats->execute();
    $count = 0 if $count < 1;
    $arg{verbose} and print "> Rows found in pg_stat_statements on remote host $remote_name: $count\n";
    my $pssinfo = $remote_get_stats->fetchall_arrayref({});

    ## Now we walk through and determine which queriyids are new. May be dupes
    my %new_queryid;
    for my $row (@$pssinfo) {
        if (!exists $known_queryid{$row->{queryid}}) {
            $new_queryid{$row->{queryid}} = 1;
        }
    }

    ## We use that list to pull back new queries and store then in the central database
    $count = $remote_get_query->execute([keys %new_queryid]);
    $count = 0 if $count < 1;
    $arg{verbose} and print "> New queries found on remote host $remote_name: $count\n";
    for my $row (@{$remote_get_query->fetchall_arrayref({})}) {

        ## Only add the first appearance of a queryid per username/dbname, to keep it simple
        next unless delete $new_queryid{$row->{queryid}};

        ## Map oid to an actually useful string
        $row->{dbname} = $dbmap{$row->{dbid}};

        $central_add_query->execute($row->{queryid}, $row->{username}, $row->{dbname}, $row->{query});

        ## Add it from the global list too
        $known_queryid{$row->{queryid}} = 1;

        if ($arg{debug} > 2) {
            $row->{query} =~ s/[\n\t]+/ /g;
            warn "Query: $row->{query}\n";
        }

    }

    ## Now we add the query stats to the central database
    ## (None of this is über efficient, but doesn't need to be as tables are small)
    for my $row (@$pssinfo) {

        ## For this row from pg_stat_statements, insert most information back into centraldb
        my @insertinfo = ($remote_time, $remote_name);
        for my $col (sort @pss_fields) {
            if (!exists $row->{$col}) {
                warn "Expected column $col for $remote_name, but nothing found\n";
                die Dumper $row;
            }
            push @insertinfo, $row->{$col};
        }
        $central_add_stat->execute(@insertinfo);
    }

    if ($arg{dryrun}) {
        $arg{verbose} and print "!! DRYRUN, so rolling back and not resetting stats\n";
        $remotedb->rollback();
        $centraldb->rollback();
        return;
    }

    ## Reset stats on the remote
    $arg{verbose} and print "> Resetting stats on $remote_name\n";
    $remotedb->do('SELECT pg_stat_statements_reset()');

    $remotedb->commit();
    $remotedb->disconnect();

    $centraldb->commit();

    $arg{verbose} and print "> Finished storing stats from remote host $remote_name\n";

    return;

} ## end of store_remote_stats

sub setup {

    my $result = GetOptions(
        \%arg,
        'debug',
        'dryrun|dry-run',
        'help',
        'quiet',
        'verbose',
        'version',
        'action=s',

        'limit=i',
        'min_mean_time=i',
        'count=i',
        'max_string=i',
        'min_calls=i',
        'timeback=s',
        'mailto=s',
        'hosts=s',
        'skiphosts=s',
        'showhosts|show_hosts|show-hosts',
        'querywrap=i',
        'showdbname',
        'dryrun|dry-run',

    ) or help();

    ++$arg{verbose} if $arg{debug};

    if ($arg{version}) {
        print "$0 version $VERSION\n";
        exit 0;
    }

    $arg{help} and help();

    $Text::Wrap::columns = $arg{querywrap};

    return;

} ## end of setup

sub help {
    print "Usage: $0 [options]\n";
    exit 0;
}

sub load_hosts {

    ## We assume this is the default location
    my $service_file = $ENV{PGSERVICEFILE} || "$ENV{HOME}/.pg_service.conf";
    open my $fh, '<', $service_file;
    while (<$fh>) {
        if (/\[(\w[\w\-]+)\]/) {
            my $host = $1;
            next if $host =~ /pitr/;    # we do not need to check pitr instances
            $hostinfo{$host} = {};
        }
    }

    ## Mark some as skipped if needed
    for my $host (keys %hostinfo) {
        if (   (length $arg{hosts} and $host !~ /$arg{hosts}/)
            or ($arg{skiphosts} and $host =~ /$arg{skiphosts}/))
        {
            $arg{debug} and print "Skipping host: $host\n";
            $hostinfo{$host}{skip} = 1;
            next;
        }
    }

    if ($arg{showhosts} or $arg{verbose} >= 2) {
        print "Hosts found in $service_file:\n\n";
        my $cols = 3;
        my $x    = 0;
        for my $host (sort keys %hostinfo) {
            printf '%-15s%s', $host, ++$x % $cols ? " " : "\n";
        }
        print "\n";
        exit 0 if $arg{showhosts};
    }

} ## end of load_hosts

sub stats_email {

    ## Send an email with some query results

    ## For now, use the common host
    my $dsn       = "dbi:Pg:service=admin";
    my $centraldb = DBI->connect(
        $dsn, '', '',
        {
            AutoCommit => 0,
            RaiseError => 1,
            PrintError => 0
        });

    my $top_queries = q{
WITH TOP AS (
  SELECT UPPER(host) AS host, queryid, sum(calls) AS sumcalls, ROUND(AVG((mean_time/1000)::NUMERIC),2) AS time
    FROM pgss_stats
   WHERE sampletime >= now() - ?::interval
   GROUP BY 1,2
)
SELECT time, host, username, sumcalls, SUBSTR( TRIM(REGEXP_REPLACE(query, '[\n ]+', ' ', 'g')), 0, ?) AS query
  FROM pgss_query
  JOIN top USING (queryid)
 WHERE sumcalls >= ?
 ORDER BY time DESC LIMIT ?
};

    my $sth = $centraldb->prepare($top_queries);
    $sth->execute($arg{timeback}, $arg{max_string}, $arg{min_calls}, $arg{count});
    my $info = $sth->fetchall_arrayref({});
    $centraldb->disconnect();
    #warn Dumper $info;

    ## Find longest string for each section
    my %longest = (
        host  => 0,
        calls => 0,
        time  => 0
    );
    for my $row (@$info) {
        for my $key (sort keys %$row) {
            $longest{$key} //= length($key);
            ## Keep this column small:
            if ($key eq 'host') {
                $row->{$key} =~ s/-dbpri0//i;
            }
            $longest{$key} = length $row->{$key} if length $row->{$key} > $longest{$key};
        }
    }

    $Text::Wrap::columns = 120;
    my $leading_space = ' ' x ($longest{host} + $longest{calls} + $longest{time} + 9);

    my $now = scalar localtime;
    my $msg = "
Report time: $now
Minimum calls: $arg{min_calls}
Time span: $arg{timeback}

";
    my $item = 0;
    for my $row (@$info) {
        my $letter = chr(65 + $item++);
        $msg .= "[$letter] Calls: $row->{sumcalls}  Average time: $row->{time}  Host: $row->{host}\n";
        $msg .= Text::Wrap::wrap(' ' x 2, ' ' x 4, $row->{query});
        $msg .= "\n\n";
    }

    if ($arg{debug}) {
        print $msg;
        print "DEBUG and END!\n";
        exit;
    }

    my $safemsg = "<pre>\n" . escapeHTML($msg) . "\n</pre>\n";

    my ($fh, $filename) = File::Temp::tempfile("/tmp/pnm.XXXXXXXX", UNLINK => 1);
    print {$fh} $safemsg;

    my $COM     = 'mail';                  ## Really bsd-mailx
    my $subject = "Weekly query report";
    my @header;
    push @header => 'Auto-Submitted: auto-generated';
    push @header => 'Precedence: bulk';
    push @header => "X-PNM-VERSION: $VERSION";
    push @header => 'Content-type: text/html';

    $COM .= qq{ -s "$subject"};
    $COM .= qq{ -a "From: $MAILFROM"} if ($MAILFROM ne '');
    for (@header) {
        $COM .= qq{ -a "$_"};
    }
    $COM .= qq{ $arg{mailto}};
    $COM .= qq{ < $filename};

    if ($arg{dryrun}) {
        print "DRY RUN! No message sent\n";
        print "<<$COM>>\n";
        print $msg;
        exit 1;
    }

    system $COM;
    $arg{verbose} and print "> Email sent to: $arg{mailto}\n";

    exit 0;

} ## end of stats_email

sub gather_stats {

    ## Gather pg_stat_statements information for a given host
    ## Arguments: one
    ## 1. Host name
    ## Returns: undef

    my $host = shift or die 'Must supply a host name!';

    $arg{verbose} > 1 and print "> Gathering stats from host: $host\n";

    ## We change milliseconds to seconds, and round a little, because nobody likes viewing milliseconds.
    my $SQL = <<EOT;
SELECT current_database() AS dbname
     , (mean_time/1000)::numeric(99,2) AS mean_seconds
     , calls
     , (min_time/1000)::numeric(99,2) AS min_seconds, (max_time/1000)::numeric(99,2) AS max_seconds
     , (stddev_time/1000)::numeric(99,2) AS stddev_seconds
     , regexp_replace(query, '[ \n\t]+', ' ','g') AS query
  FROM pg_stat_statements
 WHERE mean_time > :min_mean_time
 AND calls > :min_calls
 ORDER BY mean_time DESC, query ASC
EOT

    my $dsn     = "dbi:Pg:service=$host";
    my $statsdb = DBI->connect(
        $dsn, '', '',
        {
            AutoCommit => 0,
            RaiseError => 1,
            PrintError => 0
        });

    if ($arg{limit}) {
        $SQL .= " LIMIT $arg{limit}";
    }
    my $stats_get_info = $statsdb->prepare($SQL);
    for my $var (qw/ min_mean_time min_calls /) {
        $stats_get_info->bind_param(":$var" => $arg{$var});
    }
    my $count = $hostinfo{$host}{count} = $stats_get_info->execute();
    if ($arg{verbose} >= 1) {
        $count = 0 if $count < 1;
        print "> For host $host, rows found was: $count\n";
    }

    $hostinfo{$host}{stats} = $stats_get_info->fetchall_arrayref({});

    $statsdb->disconnect();

    return;

} ## end of gather_stats

sub host_report {

    ## Generate a report for a specific host
    ## Assumes $hostinfo{<host>}{stats} has already been populated
    ## Argumeents: one
    ## 1. Host name
    ## Returns: text report string

    my $host = shift or die;

    my $info = $hostinfo{$host} or die 'Must supply a host name!';

    my $count = $info->{count};

    my $divider = '=' x 60;
    my $notes   = "$divider\nHost:          $host\n";
    if ($arg{showdbname}) {
        $notes .= "Database:      $info->{stats}->[0]{dbname}\n";
    }
    $notes .= "Queries found: $count\n\n";

    my $number = 1;
    for my $row (@{$info->{stats}}) {
        $notes .= sprintf "[%d]\n", $number++;
        $notes .= "Seconds (mean):    $row->{mean_seconds}\n";
        $notes .= "Seconds (stddev):  $row->{stddev_seconds}\n";
        $notes .= "Times called:      $row->{sumcalls}\n";
        $notes .= "Seconds (min/max): $row->{min_seconds} / $row->{max_seconds}\n";

        my $header = 'Query: ';
        $row->{query} =~ s/^\s+//;
        my $query = Text::Wrap::wrap('', ' ' x length($header), $row->{query});
        $notes .= "$header$query\n";

        $notes .= "\n\n";
    }

    return $notes;

} ## end of host_report

__DATA__

CREATE TABLE pgss_query (
  queryid   BIGINT,
  username  TEXT,
  dbname    TEXT,
  query     TEXT
);

ALTER TABLE pgss_query ADD PRIMARY KEY (queryid);

CREATE TABLE pgss_stats (
  sampletime           TIMESTAMP(0),
  host                 TEXT,
  queryid              BIGINT,
  calls                BIGINT,
  total_time           FLOAT,
  min_time             FLOAT,
  max_time             FLOAT,
  mean_time            FLOAT,
  stddev_time          FLOAT,
  rows                 BIGINT,
  shared_blks_hit      BIGINT,
  shared_blks_read     BIGINT,
  shared_blks_dirtied  BIGINT,
  shared_blks_written  BIGINT,
  local_blks_hit       BIGINT,
  local_blks_read      BIGINT,
  local_blks_dirtied   BIGINT,
  local_blks_written   BIGINT,
  temp_blks_read       BIGINT,
  temp_blks_written    BIGINT
);

CREATE INDEX pgss_stats_queryid ON pgss_stats(queryid);

CREATE INDEX pgss_stats_mean_time ON pgss_stats(mean_time);

ALTER TABLE pgss_stats ADD FOREIGN KEY (queryid) REFERENCES pgss_query (queryid) ON DELETE CASCADE;

CREATE VIEW pgss AS
  SELECT
    host, sampletime, username, dbname, calls, rows,
  mean_time, round((mean_time/1000)::numeric,4) AS seconds,
    trim(regexp_replace(query, E'[\\n ]+', ' ', 'g')) AS query
  FROM pgss_stats a
  JOIN pgss_query USING (queryid);

