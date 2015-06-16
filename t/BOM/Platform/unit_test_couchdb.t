#!/usr/bin/perl

=head1 NAME

unit_test_couchdb.t

=head1 DESCRIPTION

Unit tests for BOM::Test::Data::Utility::UnitTestCouchDB

=cut

use 5.010;
use Test::Most;

use CouchDB::Client;

use BOM::Test::Data::Utility::UnitTestCouchDB;

my $dss = BOM::Platform::Runtime->instance->datasources;
my $couch = CouchDB::Client->new(uri => $dss->couchdb->replica->uri);

sub _test_db_names {
    return grep { $_ =~ /^zz\d+[a-z]{3}$/ } @{$couch->listDBNames};
}

lives_ok {
    BOM::Test::Data::Utility::UnitTestCouchDB::_teardown($couch);
}
'Before we start, remove any existing test DBs.';

is(_test_db_names(), 0, 'No test DBs in Couch initially.');

BOM::Test::Data::Utility::UnitTestCouchDB::_init();

my @test_DB_names = _test_db_names();
is(@test_DB_names, 9, 'Test DBs in Couch after init.');

my @DB_names_set_in_runtime_env = sort values %{$dss->couchdb_databases};

eq_or_diff([sort @test_DB_names], \@DB_names_set_in_runtime_env, 'Test DBs found in couch are same as those set in datasources.');

subtest 'keep_db' => sub {
    ok !BOM::Test::Data::Utility::UnitTestCouchDB::keep_db(), 'Default value of keep_db is false.';
    BOM::Test::Data::Utility::UnitTestCouchDB::keep_db(1);
    BOM::Test::Data::Utility::UnitTestCouchDB::_teardown($couch);
    is(_test_db_names(), 9, 'No test DBs in Couch after teardown.');

    BOM::Test::Data::Utility::UnitTestCouchDB::keep_db(0);
    BOM::Test::Data::Utility::UnitTestCouchDB::_teardown($couch);
    is(_test_db_names(), 0, 'No test DBs in Couch after teardown.');
};

done_testing;
