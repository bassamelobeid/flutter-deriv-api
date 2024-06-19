#!perl

use strict;
use warnings;
use utf8;

use Test::More;
use Syntax::Keyword::Try;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::ClientDB;
use BOM::Config;

subtest 'Writes to replica database should fail' => sub {
    my $clientdb = BOM::Database::ClientDB->new({
        broker_code => 'CR',
        operation   => 'replica',
    });

    my $dbic = $clientdb->db->dbic;

    $dbic->run(
        ping => sub {
            my $dbh = $_;
            try {
                local $dbh->{pg_errorlevel} = 2;
                local $dbh->{RaiseError}    = 1;
                local $dbh->{HandleError};

                $dbh->do('insert into betonmarkets.broker_code values (\'BRU\');');

                ok(0, 'Should not be able to write into a replica!');
            } catch {
                if ($dbh->state =~ /^25006$/) {
                    ok(1, 'read_only_sql_transaction error is thrown as expected.');
                }
            }
        });
};

done_testing();
