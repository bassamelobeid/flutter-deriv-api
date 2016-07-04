#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Test::More 0.22 tests => 5;
use Test::Exception;
use Test::NoWarnings;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use Finance::Spot::DatabaseAPI;

subtest 'Object creation' => sub {
    my $api;
    lives_ok {
        $api = Finance::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY');
    }
    'Able to create api object';

    isa_ok $api, 'Finance::Spot::DatabaseAPI';
};

subtest 'Creation makes no sense without underlying' => sub {
    throws_ok { Finance::Spot::DatabaseAPI->new(); } qr/Attribute \(underlying\) is required/, 'No Underlying';
};

subtest 'read dbh set' => sub {
    my $api = Finance::Spot::DatabaseAPI->new(underlying => 'frxUSDJPY');

    ok $api->dbh->ping, 'Able to connect to database';
};

subtest 'Historical Object creation' => sub {
    my $api;
    lives_ok {
        $api = Finance::Spot::DatabaseAPI->new(
            underlying => 'frxUSDJPY',
            historical => 1
        );
    }
    'Able to create api object';

    isa_ok $api, 'Finance::Spot::DatabaseAPI';
    ok $api->dbh->ping, 'Able to connect to database';
};
