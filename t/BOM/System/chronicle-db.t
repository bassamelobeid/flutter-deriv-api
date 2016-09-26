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

use BOM::System::Chronicle;

my $pg = Test::PostgreSQL->new or plan skip_all => $Test::PostgreSQL::errstr;

{
    my $chron = Test::MockModule->new('BOM::System::Chronicle');
    $chron->mock(_dbh_dsn => sub { $pg->dsn });
    my $dbh = BOM::System::Chronicle::_dbh();
    isa_ok($dbh, 'DBI::db');
    ok($dbh->ping, 'can ping');
    is(refaddr(BOM::System::Chronicle::_dbh()), refaddr($dbh), 'have same ref when calling _dbh again');
    ok(BOM::System::Chronicle::_dbh()->ping, 'can still ping');
    # Note that this would not be valid on win32 where all refaddrs
    # change after a "fork" anyway.
    my $addr = refaddr($dbh);
    if(my $pid = fork // die "fork failed - $!") {
        # Parent
        is(refaddr(BOM::System::Chronicle::_dbh()), refaddr($dbh), 'refaddr still the same in parent after fork');
        note 'Waiting for child process';
        waitpid $pid, 0;
    } else {
        # Child
        isnt(refaddr(my $child_dbh = BOM::System::Chronicle::_dbh()), $addr, 'refaddr changes in a fork');
        isa_ok($child_dbh, 'DBI::db');
        is(refaddr(BOM::System::Chronicle::_dbh()), refaddr($child_dbh), 'but subsequent calls get the same object');
        ok($child_dbh->ping, 'can ping the first handle');
        ok(BOM::System::Chronicle::_dbh()->ping, 'can ping the second handle');
        exit 0;
    }
}
done_testing;

