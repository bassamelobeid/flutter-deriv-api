
package BOM::Test::Data::Utility::DWTestDatabase;
use DBIx::Connector;

use 5.026;
use warnings;

our ($REPO, $DBNAME);

BEGIN {
    $REPO   //= $ENV{BOM_POSTGRES_DWDB} || '/home/git/regentmarkets/bom-postgres-dwdb';
    $DBNAME //= 'dworks';
}

sub conn {
    my $dbic = DBIx::Connector->new(
        'dbi:Pg:service=mydb',
        undef, undef,
        {
            dbi_connect_method => sub {
                local $ENV{PGSERVICEFILE} = "$REPO/pgsrv.conf";
                my $dr = shift;
                $dr->connect(@_);
            },
        });
    $dbic->mode('fixup');
    return $dbic;
}

sub psql {
    ## nocritic
    local $ENV{PGSERVICEFILE} = $REPO . '/pgsrv.conf';
    my @psql = ('psql', '-qXAt', 'service=mydb dbname=postgres', '-v', 'ON_ERROR_STOP=1', '-v', 'tmpl=' . $DBNAME . '_tmpl', '-v', 'db=' . $DBNAME);
    open my $olderr, '>&', STDERR;
    open STDERR,     '>',  '/dev/null';
    open my $fh,     '|-', @psql;
    open STDERR,     '>&', $olderr;
    # check if $fh is defined or not close it and die the function
    close $olderr;
    $fh or die "Cannot psql";
    return $fh;

}

sub refresh_db {
    system "cd $REPO && make pgtap.port pgsrv.conf >/dev/null"
        and die "Cannot create DB (make pgtap.port pgsrv.conf)";

    # We rely here on this check being a single command. If the template DB does
    # exist, we get a division by zero. In that case psql returns 3. If there is
    # no exception the database does not exist. Any other error indicates a
    # connection problem.
    my $fh = psql;
    print $fh <<'SQL';
\o /dev/null
SELECT 1/count(*) FROM pg_database WHERE datname=:'tmpl';
SQL

    my $exists = 1;

    undef $!;
    unless (close $fh) {
        die "Psql failed: $!" if $!;
        die "Psql failed" unless 3 == ($? >> 8);
        $exists = 0;
    }

    if ($exists) {
        $fh = psql;
        print $fh <<'SQL';
SELECT exists(SELECT 1 FROM pg_database WHERE datname=:'db') AS have_db\gset
\if :have_db
ALTER DATABASE :db ALLOW_CONNECTIONS false;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=:'db';
DROP DATABASE :db;
\endif
CREATE DATABASE :db WITH TEMPLATE :tmpl;
SQL
        close $fh or die "Psql failed";
    } else {
        # the template does not exist. So, even if the DB itself exists, we do
        # not know in what state it is. So, better create from scratch.
        system "cd $REPO && make clean pgtap.port pgsrv.conf >/dev/null"
            and die "Cannot create DB (make clean pgtap.port pgsrv.conf)";
        $fh = psql;
        print $fh <<'SQL';
ALTER DATABASE :db RENAME TO :tmpl;
CREATE DATABASE :db WITH TEMPLATE :tmpl;
SQL
        close $fh or die "Psql failed";
    }
}

sub import {
    my (undef, $init) = @_;

    if ($init and $init eq ':init') {
        refresh_db;
    }
}

1;
