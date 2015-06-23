use Test::Most 0.22 (tests => 7);

use Test::Exception;
use Test::NoWarnings;
use Test::MockObject;
use Test::Warn;
use strict;
use warnings;

use BOM::Platform::Data::CouchDB;
use LWP::UserAgent;
use BOM::Platform::Runtime;

#Remove master role from localhost for url generation
my $localhost = BOM::Platform::Runtime->instance->hosts->localhost;
$localhost->roles([grep { $_->name ne 'couchdb_master' } @{$localhost->roles}]);

subtest 'host building' => sub {
    lives_ok {
        my $db = BOM::Platform::Runtime->instance->datasources->couchdb->replica;
    }
    'Lived through host building';

    lives_ok {
        my $db = BOM::Platform::Runtime->instance->datasources->couchdb->master;
    }
    'Lived through host building';
};

subtest 'Default Params' => sub {
    my $db = BOM::Platform::Runtime->instance->datasources->couchdb;

    is $db->db,           'bom',       'DB ok';
    is $db->replica_host, 'localhost', 'Replica Host';
    is $db->replica_port, 5984,        'Replica Port';
    is $db->master_host,  'localhost', 'Master Host';
    is $db->master_port,  5984,        'Master Port';
};

subtest 'Specific DB Params' => sub {
    my $db = BOM::Platform::Runtime->instance->datasources->couchdb('volatility_surfaces');

    is $db->db,           'volatility_surfaces', 'DB ok';
    is $db->replica_host, 'localhost',           'Replica Host';
    is $db->replica_port, 5984,                  'Replica Port';
    is $db->master_host,  'localhost',           'Master Host';
    is $db->master_port,  5984,                  'Master Port';
};

subtest 'Test Suite translation dbname' => sub {
    BOM::Platform::Runtime->instance->datasources->couchdb_databases->{bom} = 'somewhereelse';
    my $db = BOM::Platform::Runtime->instance->datasources->couchdb('bom');
    is $db->db, 'somewhereelse', 'DB ok';
};

subtest 'Unknown translation dbname' => sub {
    my $db = BOM::Platform::Runtime->instance->datasources->couchdb('wikiwata');
    is $db->db, 'wikiwata', 'No translation for unknown db';
};

subtest 'UA parameter construction' => sub {
    my $ua = LWP::UserAgent->new(agent => 'couchdb_test');
    my $db = BOM::Platform::Runtime->instance->datasources->couchdb('bom', $ua);

    is $db->ua->agent, $ua->agent, 'Same user agent';
};
