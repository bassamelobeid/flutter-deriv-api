#!/usr/bin/perl

use strict;
use warnings;
use DBI;

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

my $table_pattern = shift;

my $chunk = 100;                # how many blocks at once 1block=8kbyte
my $sleep = 100;                # in millisec

my $dh = DBI->connect('dbi:Pg:', undef, undef, {RaiseError=>1, PrintError=>0});

my $sql_extension = <<'EOF';
CREATE EXTENSION IF NOT EXISTS pageinspect
EOF

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
   AND ($1::text IS NULL OR oid::regclass::text ~ $1::text)
EOF

my $sql_next_oid  = <<'EOF';
SELECT oid,
       oid::regclass::text,
       pg_relation_filepath(oid::regclass::text)
  FROM pg_class
 WHERE oid>$1
   AND relkind IN ('r', 'i', 'm', 't') -- regular, index, matview, toast
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

$dh->selectall_arrayref($sql_extension);
my $datadir = $dh->selectall_arrayref($sql_datadir)->[0]->[0];

for (my ($oid, $tname, $path) = @{$dh->selectall_arrayref($sql_first_oid, undef, $table_pattern)->[0] // []};
     defined ($oid);
     ($oid, $tname, $path) = @{$dh->selectall_arrayref($sql_next_oid, undef, $oid, $table_pattern)->[0] // []}) {
    print "$oid: $tname ($datadir/$path)\n";
    for my $fork (qw/main fsm vm/) { # skipping init fork
        for (my $curr_block = 0; ; $curr_block += $chunk) {
            my $l = $dh->selectall_arrayref($sql_pages, undef, $oid, $fork,
                                            $curr_block, $chunk);
            print "  @$_\n" for (@$l);
            select undef, undef, undef, $sleep/1000 if @$l;
            last if @$l < $chunk;
        }
    }
}
