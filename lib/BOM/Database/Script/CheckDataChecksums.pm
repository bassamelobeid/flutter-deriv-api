package BOM::Database::Script::CheckDataChecksums;

use strict;
use warnings;

=head1 NAME

BOM::Database::Script::CheckDataChecksums - verifies the PostgreSQL checksums against the actual data on disk

=head1 DESCRIPTION

This script scans data on disk and verifies that the calculated checksums in
the PostgreSQL metadata tables matches what we're expecting.

It's designed to be relatively low-impact: it'll scan in chunks of (default) 100
blocks (less than 1 MByte at a time), and can be run at any time.

Call this with an optional table pattern (simple regex, e.g. `users.*`) and an optional
verbose flag (to print `.` characters on output while running).

=cut

use DBIx::Connector::Pg;
use Time::HiRes qw(sleep);
use Log::Any qw($log);

sub run {
# use environment variables to connect to the database
# PGSERVICE
# PGSERVICEFILE
# PGHOST
# PGPORT
# PGDATABASE
# PGUSER
# PGPASSWORD
# PGPASSFILE
# https://www.postgresql.org/docs/9.3/static/libpq-envars.html

    my ($table_pattern, $verbose) = @_;
    die 'invalid table pattern, limited set of regex features allowed' if defined($table_pattern) and $table_pattern =~ /^[a-z0-9_.+*]+$/;

    my $start = time;
    my $chunk = 100;    # how many blocks at once 1block=8kbyte

    my $dbic = DBIx::Connector::Pg->new(
        'dbi:Pg:',
        undef, undef,
        {
            RaiseError => 1,
            PrintError => 0
        });
    my $sql_datadir = <<'EOF';
SELECT setting
  FROM pg_settings
 WHERE name='data_directory'
EOF

    my $sql_first_oid = <<'EOF';
SELECT min(oid),
       min(oid)::regclass::text,
       pg_relation_filepath(min(oid)::regclass::text)
  FROM pg_class
 WHERE relkind IN ('r', 'i', 'm', 't') -- regular, index, matview, toast
   AND relpersistence <> 't'           -- skip temporary objects
   AND ($1::text IS NULL OR oid::regclass::text ~ $1::text)
EOF

    my $sql_next_oid = <<'EOF';
SELECT oid,
       oid::regclass::text,
       pg_relation_filepath(oid::regclass::text)
  FROM pg_class
 WHERE oid>$1
   AND relkind IN ('r', 'i', 'm', 't') -- regular, index, matview, toast
   AND relpersistence <> 't'           -- skip temporary objects
   AND ($2::text IS NULL OR oid::regclass::text ~ $2::text)
 ORDER BY 1 ASC
 LIMIT 1
EOF

    my $sql_pages = <<'EOF';
SELECT $2::text, i, page_header(get_raw_page($1::oid::regclass::text, $2, ser.i))::text
  FROM pg_relation_size($1::regclass, $2) sz(sz)
 CROSS JOIN generate_series($3::int,
                            CASE WHEN (sz.sz/8192)::int < $3::int + $4::int
                                 THEN (sz.sz/8192)::int
                                 ELSE $3::int + $4::int
                            END - 1) ser(i)
 WHERE sz.sz > 0
EOF

    my $datadir = $dbic->run(fixup => sub { $_->selectall_arrayref($sql_datadir)->[0]->[0] });

    for (
        my ($oid, $tname, $path) = @{$dbic->run(fixup => sub { $_->selectall_arrayref($sql_first_oid, undef, $table_pattern)->[0] }) // []};
        defined($oid);
        ($oid, $tname, $path) = @{$dbic->run(fixup => sub { $_->selectall_arrayref($sql_next_oid, undef, $oid, $table_pattern)->[0] }) // []})
    {
        $log->debugf("%s: %s (%s)", $oid, $tname, "($datadir/$path)");
        for my $fork (qw/main fsm vm/) {    # skipping init fork
            my $n = 0;
            for (my $curr_block = 0;; $curr_block += $chunk) {
                my $l = $dbic->run(fixup => sub { $_->selectall_arrayref($sql_pages, undef, $oid, $fork, $curr_block, $chunk) });
                if (@$l < $chunk) {
                    if ($verbose) {
                        print "." unless @$l == 0;
                        print "\n" unless $n == 0 and @$l == 0;
                    }
                    last;
                } else {
                    if ($verbose) {
                        $n = ($n + 1) % 80;
                        print "*";
                        print "\n" if $n == 0;
                    }
                    sleep 0.1 if @$l;
                }
            }
        }
    }
    my $elapsed = time - $start;
    printf "Checksum verification complete for %s in %d seconds\n", $ENV{PGSERVICE}, $elapsed;
    return 0;
}

1;
