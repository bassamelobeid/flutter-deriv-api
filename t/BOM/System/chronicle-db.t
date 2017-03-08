use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::PostgreSQL;
# Note that the Test2 framework encourages Test2::IPC instead,
# since this provides better integration with tests in child
# processes.
use Test::SharedFork;
use Scalar::Util qw(refaddr);

use BOM::Platform::Chronicle;
use DBIx::TransactionManager::Distributed;

my $pg = Test::PostgreSQL->new or plan skip_all => $Test::PostgreSQL::errstr;

{
    my $chron = Test::MockModule->new('BOM::Platform::Chronicle');
    $chron->mock(_dbh_dsn => sub { $pg->dsn });
    my $dbh = BOM::Platform::Chronicle::_dbh();
    isa_ok($dbh, 'DBI::db');
    ok($dbh->ping, 'can ping');
    ok(DBIx::TransactionManager::Distributed::dbh_is_registered(chronicle => $dbh), 'this handle is registered with BOM::Database');
    is(refaddr(BOM::Platform::Chronicle::_dbh()), refaddr($dbh), 'have same ref when calling _dbh again');
    ok(BOM::Platform::Chronicle::_dbh()->ping, 'can still ping');
    # Note that this would not be valid on win32 where all refaddrs
    # change after a "fork" anyway.
    my $addr = refaddr($dbh);
    if (my $pid = fork // die "fork failed - $!") {
        # Parent
        is(refaddr(BOM::Platform::Chronicle::_dbh()), $addr, 'refaddr still the same in parent after fork');
        ok(DBIx::TransactionManager::Distributed::dbh_is_registered(chronicle => $dbh), 'and handle is still registered with BOM::Database');
        note 'Waiting for child process';
        waitpid $pid, 0;
    } else {
        # Child
        ok(
            !DBIx::TransactionManager::Distributed::dbh_is_registered(chronicle => $dbh),
            'original handle reports as no longer registered with BOM::Database'
        );
        isnt(refaddr(my $child_dbh = BOM::Platform::Chronicle::_dbh()), $addr, 'refaddr changes in a fork');
        isa_ok($child_dbh, 'DBI::db');
        is(refaddr(BOM::Platform::Chronicle::_dbh()), refaddr($child_dbh), 'but subsequent calls get the same object');
        ok(DBIx::TransactionManager::Distributed::dbh_is_registered(chronicle => $child_dbh), 'new handle is registered with BOM::Database');
        ok($child_dbh->ping,                       'can ping the first handle');
        ok(BOM::Platform::Chronicle::_dbh()->ping, 'can ping the second handle');
        exit 0;
    }
}
done_testing;

