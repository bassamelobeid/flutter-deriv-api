#!/usr/bin/perl

use strict;
use warnings;

use Test::More qw/tests 24/;
use Test::NoWarnings ();    # don't call ->import to avoid had_no_warnings to be
                            # called in an END block. We call it explicitly instead.
use Test::Warn;
use Test::Exception;

use BOM::Database::ClientDB;
use BOM::Test::Data::Utility::UnitTestDatabase;

my $ctrl;

sub terminate_backend {
    my $dbh = $_[0];

    my $stmt = $ctrl->prepare('SELECT pg_terminate_backend($1)');
    $stmt->execute($dbh->{pg_pid});

    my $success;
    while (my $row = $stmt->fetchrow_arrayref) {
        $success = $row->[0];
    }

    return $success;
}

sub a_query {
    my $dbh = $_[0];

    # we read the backend pid again, but in fact any query would do

    my $stmt = $dbh->prepare('SELECT pg_backend_pid()');
    $stmt->execute;

    my $rc;
    while (my $row = $stmt->fetchrow_arrayref) {
        $rc = $row->[0];
    }

    return $rc;
}

# we need 2 almost identical DBI handles / postgres backends here. One of them,
# $ctrl, is later used to kill the other one, $dbh.

note "First build the control handle to be able to terminate the other backend";

my $cb = BOM::Database::ClientDB->new({
    broker_code => 'CR',
});

my $dbh = $cb->db->dbh;
{
    my $cache = $dbh->{Driver}->{CachedKids};
    %$cache = () if $cache;
}

$ctrl = $dbh->clone(+{});
{
    my $cache = $ctrl->{Driver}->{CachedKids};
    %$cache = () if $cache;
}

note "Now clear the handle cache and get a new handle";

$dbh->disconnect;
BOM::Database::Rose::DB->db_cache->clear;

# real tests start here

# At this point the Rose DB cache is empty. $ctrl is a connection that
# is otherwise unknown. So, except for $ctrl, the state is pristine.

$cb = BOM::Database::ClientDB->new({
    broker_code => 'CR',
});

isa_ok $cb, 'BOM::Database::ClientDB';

$dbh = $cb->db->dbh;
isa_ok $ctrl, 'DBI::db';
isa_ok $dbh,  'DBI::db';

my $dbh_pid  = $dbh->{pg_pid};
my $ctrl_pid = $ctrl->{pg_pid};

isnt $dbh_pid, $ctrl_pid, "dbh_pid=$dbh_pid differs from ctrl_pid=$ctrl_pid";

note "\npreconditions met -- testing non-UI case\n\n";

# fetching the connection from Rose cache

$cb = BOM::Database::ClientDB->new({
    broker_code => 'CR',
});
$dbh = $cb->db->dbh;

is a_query($dbh), $dbh_pid, 'still getting the correct backend pid';

is terminate_backend($dbh), '1', 'backend terminated';

$cb = BOM::Database::ClientDB->new({
    broker_code => 'CR',
});
$dbh = $cb->db->dbh;

isnt a_query($dbh), $dbh_pid, 'got different backend pid';

# establishing pristine state again

$dbh->disconnect;
BOM::Database::Rose::DB->db_cache->clear;

note "\ntesting UI case\n\n";

{
    $cb = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });
    $dbh     = $cb->db->dbh;
    $dbh_pid = $dbh->{pg_pid};

    is a_query($dbh), $dbh_pid, "got backend pid $dbh_pid";

    # This method is called by Sysinit.pm at the end of each HTTP request
    # It aborts any current transaction and discards all other resources
    # attached to the backend.

    $dbh->begin_work;
    throws_ok {
        warning_like {
            $dbh->do('select 1/0');
        } qr/division by zero/;
    }
    qr/division by zero/, 'connection now in faulty transaction state';

    throws_ok {
        warning_like {
            $dbh->do('select 1');
        } qr/current transaction is aborted/;
    }
    qr/current transaction is aborted/, 'transaction aborted state';

    BOM::Database::Rose::DB->db_cache->finish_request_cycle;

    # Since we are using connect_cached in the UI case, we must get the
    # same backend here. Note, this does not come from the Rose cache
    # but from the cache inside DBI.

    $cb = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });
    $dbh = $cb->db->dbh;

    lives_ok {
        is $dbh->{AutoCommit}, 1, 'AutoCommit is now on';
        is a_query($dbh), $dbh_pid, "still the same backend pid $dbh_pid";
    }
    'faulty transaction rolled back';

    # make the handle unusable and finish the request cycle.

    warning_like { is terminate_backend($dbh), '1', 'backend terminated' } qr/backend terminated/;

    lives_ok {
        warning_like {
            BOM::Database::Rose::DB->db_cache->finish_request_cycle;
        } qr/terminating connection/;
    }
    'cache->finish_request_cycle survives a terminated backend';

    # now expect to get a different backend

    $cb = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });
    $dbh = $cb->db->dbh;

    isnt a_query($dbh), $dbh_pid, "different backend";

    $dbh_pid = $dbh->{pg_pid};

    $cb = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });
    $dbh = $cb->db->dbh;

    is a_query($dbh), $dbh_pid, "still the same backend pid $dbh_pid";

    lives_ok {
        $dbh->do('create temp table vafdbtujrwty(i int)');
        $dbh->do('insert into vafdbtujrwty(i) values(1)');
    }
    'created temp table and inserted a row';

    BOM::Database::Rose::DB->db_cache->finish_request_cycle;

    # here the temp table must be gone

    $cb = BOM::Database::ClientDB->new({
        broker_code => 'CR',
    });
    $dbh = $cb->db->dbh;

    is a_query($dbh), $dbh_pid, "still the same backend pid $dbh_pid";

    throws_ok {
        warning_like {
            $dbh->do('insert into vafdbtujrwty(i) values(2)');
        } qr/relation "vafdbtujrwty" does not exist/;
    }
    qr/relation "vafdbtujrwty" does not exist/, 'DISCARD ALL during ->finish_request_cycle';
}

Test::NoWarnings::had_no_warnings;

done_testing;
