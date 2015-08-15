use Test::Most 0.22 (tests => 7);

use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use strict;
use warnings;
use Bytes::Random::Secure;
use CouchDB::Client;

use BOM::Platform::Data::CouchDB;
use LWP::UserAgent;
use HTTP::Request;
use Cache::RedisDB;

subtest 'builds' => sub {
    subtest 'host & port' => sub {
        my $couch = BOM::Platform::Data::CouchDB->new(
            replica_host => 'localhost',
            replica_port => 5984,
            master_host  => 'localhost',
            master_port  => 5984
        );

        isa_ok $couch->replica, 'BOM::Platform::Data::CouchDB::Connection';
        isa_ok $couch->master,  'BOM::Platform::Data::CouchDB::Connection';

        is $couch->master->protocol,  'http://';
        is $couch->replica->protocol, 'http://';
    };

    subtest 'host, port & password' => sub {
        my $couch = BOM::Platform::Data::CouchDB->new(
            replica_host => 'localhost',
            replica_port => 5984,
            master_host  => 'localhost',
            master_port  => 5984,
            couchdb      => 'letmein'
        );

        isa_ok $couch->replica, 'BOM::Platform::Data::CouchDB::Connection';
        isa_ok $couch->master,  'BOM::Platform::Data::CouchDB::Connection';

        is $couch->master->protocol,  'http://';
        is $couch->replica->protocol, 'http://';

        is $couch->master->couchdb,  'letmein';
        is $couch->replica->couchdb, 'letmein';
    };

    subtest 'host, port & protocol' => sub {
        my $couch = BOM::Platform::Data::CouchDB->new(
            replica_host     => 'localhost',
            replica_port     => 5984,
            replica_protocol => 'https://',
            master_host      => 'localhost',
            master_port      => 5984,
            master_protocol  => 'https://'
        );

        isa_ok $couch->replica, 'BOM::Platform::Data::CouchDB::Connection';
        isa_ok $couch->master,  'BOM::Platform::Data::CouchDB::Connection';

        is $couch->master->protocol,  'https://';
        is $couch->replica->protocol, 'https://';
    };
};
my $test_db = 'couch_ds_test';
subtest 'postive' => sub {
    my $couch = BOM::Platform::Data::CouchDB->new(
        replica_host => 'localhost',
        replica_port => 5984,
        master_host  => 'localhost',
        master_port  => 5984,
        db           => $test_db
    );

    my $client = CouchDB::Client->new(uri => $couch->master->uri);
    eval { $client->newDB($test_db)->delete; };

    subtest 'build' => sub {
        isa_ok $couch->replica, 'BOM::Platform::Data::CouchDB::Connection';
        isa_ok $couch->master,  'BOM::Platform::Data::CouchDB::Connection';

        is $couch->master->protocol,  'http://';
        is $couch->replica->protocol, 'http://';

        ok $couch->can_read,  'Can Read';
        ok $couch->can_write, 'Can Write';
    };

    subtest 'interface' => sub {
        ok $couch->create_database();
        ok $couch->create_document('test_doc');
        my $contents = {'planet' => 'Mars'};
        ok $couch->document('test_doc', $contents);
        my $retrieved = $couch->document('test_doc');
        ok $couch->document_present('test_doc');
        is_deeply($contents, $retrieved, 'Stored & Retrieved are same');
        my $view = {all => {map => 'function(doc) { emit(doc._id, doc._rev) }'}};
        ok $couch->master->create_or_update_view($view);
        ok $couch->view('all');
        ok $couch->delete_document('test_doc');
        ok !$couch->document_present('test_doc');
    };

    subtest 'nameless document' => sub {
        my $doc_name = $couch->create_document();
        ok $doc_name;
        ok $couch->document($doc_name, {reached => 1});
        my $new_doc = $couch->document($doc_name);
        is $new_doc->{reached}, 1, 'Correct content';
    };
};

subtest 'caching' => sub {
    my $doc_name = Bytes::Random::Secure->new(Bits => 160, NonBlocking => 1)->string_from("TheCompleatWilliamShakespere", 12);
    subtest 'setup' => sub {
        my $couch = BOM::Platform::Data::CouchDB->new(
            replica_host => 'localhost',
            replica_port => 5984,
            master_host  => 'localhost',
            master_port  => 5984
        );
        ok $couch->create_document($doc_name), 'create ' . $doc_name;
        my $contents = {'planet' => 'Mars'};
        ok $couch->document($doc_name, $contents), 'contents of ' . $doc_name . ' match';
    };
    subtest 'with cache' => sub {
        my $couch = BOM::Platform::Data::CouchDB->new(
            replica_host => 'localhost',
            replica_port => 5984,
            master_host  => 'localhost',
            master_port  => 5984
        );
        ok $couch->document($doc_name), 'load ' . $doc_name;
        ok(Cache::RedisDB->get('COUCH_DOCS', 'bom_' . $doc_name), 'find ' . $doc_name . ' in Cache');
        ok(Cache::RedisDB->del('COUCH_DOCS', 'bom_' . $doc_name), 'delete ' . $doc_name . ' from Cache');
    };

    subtest 'without cache' => sub {
        my $module = new Test::MockModule('Cache::RedisDB');
        $module->mock('new_redis', sub { die "redis not present" });
        my $couch = BOM::Platform::Data::CouchDB->new(
            replica_host => 'localhost',
            replica_port => 5984,
            master_host  => 'localhost',
            master_port  => 5984
        );
        ok $couch->document($doc_name), 'get document ' . $doc_name;
        ok !Cache::RedisDB->get('COUCH_DOCS', 'bom_my_doc'), $doc_name . ' not present in cache.';
    };

    subtest 'teardown' => sub {
        my $couch = BOM::Platform::Data::CouchDB->new(
            replica_host => 'localhost',
            replica_port => 5984,
            master_host  => 'localhost',
            master_port  => 5984
        );
        ok $couch->delete_document($doc_name), 'delete ' . $doc_name . ' from Couch.';
    };
};

subtest 'replica_executions' => sub {
    my $couch = BOM::Platform::Data::CouchDB->new(
        replica_host => '127.0.0.2',
        replica_port => 5984,
        master_host  => 'localhost',
        master_port  => 5984,
        db           => $test_db
    );

    ok !$couch->can_read, 'Cannot Read';
    ok $couch->can_write, 'Can Write';

    throws_ok {
        $couch->document('test');
    }
    'BOM::Platform::Data::CouchDB::ConnectionFailed';

    throws_ok {
        $couch->view('test');
    }
    'BOM::Platform::Data::CouchDB::ConnectionFailed';

    ok !$couch->document_present('test');
};

subtest 'master_executions' => sub {
    my $couch = BOM::Platform::Data::CouchDB->new(
        replica_host => 'localhost',
        replica_port => 5984,
        master_host  => '127.0.0.2',
        master_port  => 5984,
        db           => 'test'
    );

    ok $couch->can_read, 'Cannot Read';
    ok !$couch->can_write, 'Can Write';

    throws_ok {
        $couch->create_database();
    }
    'BOM::Platform::Data::CouchDB::ConnectionFailed';

    throws_ok {
        $couch->create_document('test');
    }
    'BOM::Platform::Data::CouchDB::ConnectionFailed';

    throws_ok {
        $couch->document('test', {galaxy => ['planets', 'stars', 'debris']});
    }
    'BOM::Platform::Data::CouchDB::ConnectionFailed';

    throws_ok {
        $couch->delete_document('test');
    }
    'BOM::Platform::Data::CouchDB::ConnectionFailed';
};

subtest 'teardown' => sub {
    my $couch = BOM::Platform::Data::CouchDB->new(
        replica_host => 'localhost',
        replica_port => 5984,
        master_host  => 'localhost',
        master_port  => 5984
    );
    my $client = CouchDB::Client->new(uri => $couch->master->uri);
    ok $client->newDB($test_db)->delete, 'Test DB deleted';
};
