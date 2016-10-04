#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 4;
use Test::Exception;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Postgres::FeedDB::Spot::DatabaseAPI;

use Postgres::FeedDB::Spot::DatabaseAPI;
my $dbh = BOM::Database::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'Object creation' => sub {
    my $api;
    lives_ok {
        $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);
    }
    'Able to create api object';

    isa_ok $api, 'Postgres::FeedDB::Spot::DatabaseAPI';
};

subtest 'Creation makes no sense without underlying or db handler' => sub {
    throws_ok { Postgres::FeedDB::Spot::DatabaseAPI->new(db_handle => undef); } qr/Attribute \(underlying\) is required/, 'No Underlying';
    throws_ok { Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => undef); } qr/Attribute \(db_handle\) is required/, 'No Underlying';
};

subtest 'read dbh set' => sub {
    my $api = Postgres::FeedDB::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', db_handle => $dbh);

    ok $api->dbh->ping, 'Able to connect to database';
};

subtest 'Historical Object creation' => sub {
    my $api;
    lives_ok {
        $api = Postgres::FeedDB::Spot::DatabaseAPI->new(
            underlying => 'frxUSDJPY',
            historical => 1,
            db_handle  => $dbh,
        );
    }
    'Able to create api object';

    isa_ok $api, 'Postgres::FeedDB::Spot::DatabaseAPI';
    ok $api->db_handle->ping, 'Able to connect to database';
};
