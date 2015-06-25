#!/bin/bash

# reset_rmgdb.sh <<<letmein

: ${PGHOST:=localhost} ${PGPORT:=5432} ${PGPASSFILE:=~/.pgpass$$}
export PGHOST PGPORT PGPASSFILE

[ -f "$PGPASSFILE" ] || {
    trap 'rm "$PGPASSFILE"' EXIT INT TERM
    : >"$PGPASSFILE"
    chmod 600 "$PGPASSFILE"
    pw="$(head -1)"
    echo "$PGHOST:$PGPORT:postgres:postgres:$pw" >>"$PGPASSFILE"
    echo "$PGHOST:$PGPORT:regentmarkets:postgres:$pw" >>"$PGPASSFILE"
}

psql -w postgres postgres <<EOF
SELECT pg_terminate_backend(t.pid)
  FROM pg_stat_get_activity(NULL::int) t(datid, pid)
  JOIN pg_database d ON t.datid=d.oid
 WHERE pid<>pg_backend_pid()
   AND d.datname='regentmarkets';
DROP DATABASE regentmarkets;
CREATE DATABASE regentmarkets;
EOF

/home/git/regentmarkets/bom-postgres/bin/dbmigration.pl \
  --yes --hostname="$PGHOST" --port="$PGPORT" --username=postgres --database=regentmarkets --dbset=rmg

psql -w regentmarkets postgres <<EOF
INSERT INTO betonmarkets.broker_code VALUES ('CR'), ('VRTC'), ('MX'),('MLT'), ('MF') ;
EOF
