#!/etc/rmg/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 5;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Finance::Spot::DatabaseAPI;

use Finance::Spot::DatabaseAPI;
my $dbh = BOM::Database::FeedDB::read_dbh;
$dbh->{RaiseError} = 1;

subtest 'Object creation' => sub {
    my $api;
    lives_ok {
        $api = Finance::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', dbh => $dbh);
    }
    'Able to create api object';

    isa_ok $api, 'Finance::Spot::DatabaseAPI';
};

subtest 'Creation makes no sense without underlying or db handler' => sub {
    throws_ok { Finance::Spot::DatabaseAPI->new(dbh => undef); } qr/Attribute \(underlying\) is required/, 'No Underlying';
    throws_ok { Finance::Spot::DatabaseAPI->new(underlying => undef); } qr/Attribute \(dbh\) is required/, 'No Underlying';
};

subtest 'read dbh set' => sub {
    my $api = Finance::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY', dbh => $dbh);

    ok $api->dbh->ping, 'Able to connect to database';
};

subtest 'Historical Object creation' => sub {
    my $api;
    lives_ok {
        $api = Finance::Spot::DatabaseAPI->new(
            underlying => 'frxUSDJPY',
            historical => 1,
            dbh        => $dbh,
        );
    }
    'Able to create api object';

    isa_ok $api, 'Finance::Spot::DatabaseAPI';
    ok $api->dbh->ping, 'Able to connect to database';
};
